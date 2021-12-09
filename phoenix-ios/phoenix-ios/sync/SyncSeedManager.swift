import Foundation
import PhoenixShared
import CloudKit
import Combine
import Network
import os.log

#if DEBUG && true
fileprivate var log = Logger(
	subsystem: Bundle.main.bundleIdentifier!,
	category: "SyncSeedManager"
)
#else
fileprivate var log = Logger(OSLog.disabled)
#endif

fileprivate let record_column_mnemonics = "mnemonics"
fileprivate let record_column_language = "language"
fileprivate let record_column_name = "name"

struct SeedBackup {
	let mnemonics: String
	let language: String
	let name: String?
	let created: Date
}

enum FetchSeedsError: Error {
	case cloudKit(underlying: CKError)
	case unknown(underlying: Error)
}

fileprivate struct AtomicState {
	var waitingForInternet = true
	var waitingForCloudCredentials = true
	
	var isEnabled: Bool
	var needsUploadSeed: Bool
	var needsDeleteSeed: Bool
	
	var active: SyncSeedManager_State
	
	init(isEnabled: Bool, hasUploadedSeed: Bool) {
		self.isEnabled = isEnabled
		if isEnabled {
			needsUploadSeed = !hasUploadedSeed
			needsDeleteSeed = false
		} else {
			needsUploadSeed = false
			needsDeleteSeed = hasUploadedSeed
		}
		
		if !isEnabled && !needsDeleteSeed {
			active = .disabled
		} else {
			active = .initializing
		}
	}
}

// --------------------------------------------------------------------------------
// MARK: -
// --------------------------------------------------------------------------------

/// Encompasses the logic for syncing seeds with Apple's CloudKit database.
///
class SyncSeedManager {
	
	/// The chain in use by PhoenixBusiness (e.g. Testnet)
	///
	private let chain: Chain
	
	/// The 12-word seed phrase for the wallet.
	///
	private let mnemonics: String
	
	/// The encryptedNodeId is created via: Hash(cloudKey + nodeID)
	///
	/// All data from a user's wallet are stored in the user's CKContainer.default().privateCloudDatabase.
	/// And within the privateCloudDatabase, we create a dedicated CKRecordZone for each wallet,
	/// where recordZone.name == encryptedNodeId. All trasactions for the wallet are stored in this recordZone.
	///
	/// For simplicity, the name of the uploaded Seed shared the encryptedNodeId name.
	///
	private let encryptedNodeId: String
	
	/// Informs the user interface regarding the activities of the SyncSeedManager.
	/// This includes various errors & active upload progress.
	///
	/// Changes to this publisher will always occur on the main thread.
	///
	public let statePublisher: CurrentValueSubject<SyncSeedManager_State, Never>
	
	private let record_table_name: String
	
	private let queue = DispatchQueue(label: "SyncSeedManager")
	private var state: AtomicState // must be read/modified within queue
	
	private let networkMonitor: NWPathMonitor
	
	private var consecutiveErrorCount = 0
	
	private var cancellables = Set<AnyCancellable>()
	
	init(chain: Chain, mnemonics: [String], encryptedNodeId: String) {
		log.trace("init()")
		
		self.chain = chain
		self.mnemonics = mnemonics.joined(separator: " ")
		self.encryptedNodeId = encryptedNodeId
		
		record_table_name = SyncSeedManager.record_table_name(chain: chain)
		
		state = AtomicState(
			isEnabled: Prefs.shared.backupSeed_isEnabled,
			hasUploadedSeed: Prefs.shared.hasUploadedSeed(encryptedNodeId: encryptedNodeId)
		)
		statePublisher = CurrentValueSubject<SyncSeedManager_State, Never>(state.active)
		
		networkMonitor = NWPathMonitor()
		startNetworkMonitor()
		startCloudStatusMonitor()
		startPreferencesMonitor()
		checkForCloudCredentials()
	}
	
	// ----------------------------------------
	// MARK: Fetch Seeds
	// ----------------------------------------
	
	private class func record_table_name(chain: Chain) -> String {
		
		// From Apple's docs:
		// > A record type must consist of one or more alphanumeric characters
		// > and must start with a letter. CloudKit permits the use of underscores,
		// > but not spaces.
		//
		var allowed = CharacterSet.alphanumerics
		allowed.insert("_")
		
		let suffix = chain.name.lowercased().components(separatedBy: allowed.inverted).joined(separator: "")
		
		return "seeds_bitcoin_\(suffix)"
	}
	
	public class func fetchSeeds(chain: Chain) -> PassthroughSubject<SeedBackup, FetchSeedsError> {
		
		let publisher = PassthroughSubject<SeedBackup, FetchSeedsError>()
		
		var startBatchFetch     : (() -> Void)!
		var recursiveBatchFetch : ((CKQueryOperation) -> Void)!
		
		startBatchFetch = {
			log.trace("fetchSeeds(): startBatchFetch()")
			
			let predicate = NSPredicate(format: "TRUEPREDICATE")
			let query = CKQuery(
				recordType: record_table_name(chain: chain),
				predicate: predicate
			)
			query.sortDescriptors = [
				NSSortDescriptor(key: "creationDate", ascending: false)
			]
			
			let operation = CKQueryOperation(query: query)
			operation.zoneID = CKRecordZone.default().zoneID
			
			recursiveBatchFetch(operation)
		}
		
		recursiveBatchFetch = { (operation: CKQueryOperation) in
			log.trace("fetchSeeds(): recursiveBatchFetch()")
			
			let recordMatchedBlock = {(recordID: CKRecord.ID, result: Result<CKRecord, Error>) in
				
				if case .success(let record) = result {
					
					if let mnemonics = record[record_column_mnemonics] as? String,
						let language = record[record_column_language] as? String,
						let name = record[record_column_name] as? String?
					{
						let item = SeedBackup(
							mnemonics: mnemonics,
							language: language,
							name: name,
							created: record.creationDate ?? Date.distantPast
						)
						
						publisher.send(item)
					}
				}
			}
			
			let queryResultBlock = {(result: Result<CKQueryOperation.Cursor?, Error>) in

				switch result {
				case .success(let cursor):

					if let cursor = cursor {
						log.debug("fetchSeeds(): queryResultBlock(): moreInCloud = true")
						recursiveBatchFetch(CKQueryOperation(cursor: cursor))

					} else {
						log.debug("fetchSeeds(): queryResultBlock(): moreInCloud = false")
						publisher.send(completion: .finished)
					}

				case .failure(let error):

					if let ckerror = error as? CKError {
						publisher.send(completion: .failure(.cloudKit(underlying: ckerror)))
					} else {
						publisher.send(completion: .failure(.unknown(underlying: error)))
					}
				}
			}

			if #available(iOS 15.0, *) {
				operation.recordMatchedBlock = recordMatchedBlock
				operation.queryResultBlock = queryResultBlock
			} else {
				operation.recordFetchedBlock = {(record: CKRecord) in
					recordMatchedBlock(record.recordID, Result.success(record))
				}
				operation.queryCompletionBlock = {(cursor: CKQueryOperation.Cursor?, error: Error?) in
					if let error = error {
						queryResultBlock(.failure(error))
					} else {
						queryResultBlock(.success(cursor))
					}
				}
			}
		
			let configuration = CKOperation.Configuration()
			configuration.allowsCellularAccess = true
			operation.configuration = configuration

			CKContainer.default().privateCloudDatabase.add(operation)
		}
		
		startBatchFetch()
		return publisher
	}
	
	// ----------------------------------------
	// MARK: Monitors
	// ----------------------------------------
	
	private func startNetworkMonitor() {
		log.trace("startNetworkMonitor()")
		
		networkMonitor.pathUpdateHandler = {[weak self](path: NWPath) -> Void in
			
			let hasInternet: Bool
			switch path.status {
				case .satisfied:
					log.debug("nwpath.status.satisfied")
					hasInternet = true
					
				case .unsatisfied:
					log.debug("nwpath.status.unsatisfied")
					hasInternet = false
					
				case .requiresConnection:
					log.debug("nwpath.status.requiresConnection")
					hasInternet = true
					
				@unknown default:
					log.debug("nwpath.status.unknown")
					hasInternet = false
			}
			
			self?.updateState { state, deferToSimplifiedStateFlow in

				if hasInternet {
					state.waitingForInternet = false

					switch state.active {
						case .initializing:
							deferToSimplifiedStateFlow = true
						case .waiting(let details):
							switch details.kind {
								case .forInternet:
									deferToSimplifiedStateFlow = true
								default: break
							}
						default: break
					}

				} else {
					state.waitingForInternet = true

					switch state.active {
						case .initializing: fallthrough
						case .synced:
							log.debug("state.active = waiting(forInternet)")
							state.active = .waiting_forInternet()
						default: break
					}
				}
			}
		}
		
		networkMonitor.start(queue: DispatchQueue.main)
	}
	
	private func startCloudStatusMonitor() {
		log.trace("startCloudStatusMonitor()")
		
		NotificationCenter.default.publisher(for: Notification.Name.CKAccountChanged)
			.sink {[weak self] _ in
			
			log.debug("CKAccountChanged")
			DispatchQueue.main.async {
				self?.checkForCloudCredentials()
			}
			
		}.store(in: &cancellables)
	}
	
	private func startPreferencesMonitor() {
		log.trace("startPreferencesMonitor()")
		
		var isFirstFire = true
		Prefs.shared.backupSeed_isEnabledPublisher.sink {[weak self](shouldEnable: Bool) in
			
			if isFirstFire {
				isFirstFire = false
				return
			}
			
			log.debug("Prefs.shared.backupSeed_isEnabledPublisher = \(shouldEnable ? "true" : "false")")

			self?.updateState { state, deferToSimplifiedStateFlow in
				
				if shouldEnable {
					
					if !state.isEnabled {
					
						log.debug("Transitioning to enabled state")
						
						state.isEnabled = true
						state.needsUploadSeed = true
						state.needsDeleteSeed = false
						
						switch state.active {
							case .waiting(let details):
								// Careful: calling `details.skip` within `queue.sync` will cause deadlock.
								DispatchQueue.global(qos: .default).async {
									details.skip()
								}
							case .disabled:
								deferToSimplifiedStateFlow = true
							default: break
						}
						
					} else {
						log.debug("Reqeust to transition to enabled state, but already enabled")
					}

				} else /* if !shouldEnable */ {
					
					if state.isEnabled {
					
						log.debug("Transitioning to disabled state")
						
						state.isEnabled = false
						state.needsUploadSeed = false
						state.needsDeleteSeed = true
						
						switch state.active {
							case .waiting(let details):
								// Careful: calling `details.skip` within `queue.sync` will cause deadlock.
								DispatchQueue.global(qos: .default).async {
									details.skip()
								}
							case .synced:
								deferToSimplifiedStateFlow = true
							default: break
						}
						
					} else {
						log.debug("Request to transition to disabled state, but already disabled")
					}
				}
			}
			
		}.store(in: &cancellables)
	}
	
	// ----------------------------------------
	// MARK: Publishers
	// ----------------------------------------
	
	private func publishNewState(_ state: SyncSeedManager_State) {
		log.trace("publishNewState()")
		
		let block = {
			self.statePublisher.value = state
		}
		
		if Thread.isMainThread {
			block()
		} else {
			DispatchQueue.main.async { block() }
		}
	}
	
	// ----------------------------------------
	// MARK: State Machine
	// ----------------------------------------
	
	func updateState(finishing waiting: SyncSeedManager_State_Waiting) {
		log.trace("updateState(finishing waiting)")
		
		updateState { state, deferToSimplifiedStateFlow in
			
			guard case .waiting(let details) = state.active, details == waiting else {
				// Current state doesn't match parameter.
				// So we ignore the function call.
				return
			}
			
			switch details.kind {
				case .exponentialBackoff:
					deferToSimplifiedStateFlow = true
				default:
					break
			}
		}
	}
	
	private func updateState(_ modifyStateBlock: (inout AtomicState, inout Bool) -> Void) {
		
		var changedState: SyncSeedManager_State? = nil
		queue.sync {
			let prvActive = state.active
			var deferToSimplifiedStateFlow = false
			modifyStateBlock(&state, &deferToSimplifiedStateFlow)
			
			if deferToSimplifiedStateFlow {
				// State management deferred to this function.
				// Executing simplified state flow.
				
				if state.waitingForCloudCredentials {
					state.active = .waiting_forCloudCredentials()
				} else if state.waitingForInternet {
					state.active = .waiting_forInternet()
				} else if state.isEnabled {
					if state.needsUploadSeed {
						state.active = .uploading
					} else {
						state.active = .synced
					}
				} else {
					if state.needsDeleteSeed {
						state.active = .deleting
					} else {
						state.active = .disabled
					}
				}
			
			} // </simplified_state_flow>
			
			if prvActive != state.active {
				changedState = state.active
			}
		
		} // </queue.sync>
		
		if let newState = changedState {
			log.debug("state.active = \(newState)")
			switch newState {
				case .uploading:
					uploadSeed()
				case .deleting:
					deleteSeed()
				default:
					break
			}
			
			publishNewState(newState)
		}
	}
	
	// ----------------------------------------
	// MARK: Flow
	// ----------------------------------------
	
	private func checkForCloudCredentials() {
		log.trace("checkForCloudCredentials")
		
		CKContainer.default().accountStatus {[weak self] (accountStatus: CKAccountStatus, error: Error?) in
			
			if let error = error {
				log.warning("Error fetching CKAccountStatus: \(String(describing: error))")
			}
			
			var hasCloudCredentials: Bool
			switch accountStatus {
				case .available:
					log.debug("CKAccountStatus.available")
					hasCloudCredentials = true
					
				case .noAccount:
					log.debug("CKAccountStatus.noAccount")
					hasCloudCredentials = false
					
				case .restricted:
					log.debug("CKAccountStatus.restricted")
					hasCloudCredentials = false
					
				case .couldNotDetermine:
					log.debug("CKAccountStatus.couldNotDetermine")
					hasCloudCredentials = false
					
				case .temporarilyUnavailable:
					log.debug("CKAccountStatus.temporarilyUnavailable")
					hasCloudCredentials = false
				
				@unknown default:
					log.debug("CKAccountStatus.unknown")
					hasCloudCredentials = false
			}
			
			self?.updateState { state, deferToSimplifiedStateFlow in

				if hasCloudCredentials {
					state.waitingForCloudCredentials = false

					switch state.active {
						case .initializing:
							deferToSimplifiedStateFlow = true
						case .waiting(let details):
							switch details.kind {
								case .forCloudCredentials:
									deferToSimplifiedStateFlow = true

								default: break
							}
						default: break
					}

				} else {
					state.waitingForCloudCredentials = true

					switch state.active {
						case .initializing:
							deferToSimplifiedStateFlow = true
						case .synced:
							log.debug("state.active = waiting(forCloudCredentials)")
							state.active = .waiting_forCloudCredentials()

						default: break
					}
				}
			}
		}
	}
	
	private func uploadSeed() {
		log.trace("uploadSeed()")
		
		let finish = { (result: Result<Void, Error>) in
			
			switch result {
			case .success:
				log.trace("uploadSeed(): finish(): success")
				
				self.consecutiveErrorCount = 0
				self.updateState { state, deferToSimplifiedStateFlow in
					switch state.active {
						case .uploading:
							state.active = .synced
						default:
							break
					}
				}
				
			case .failure(let error):
				log.trace("uploadSeed(): finish(): failure")
				self.handleError(error)
			}
		}
		
		let record = CKRecord(
			recordType: record_table_name,
			recordID: CKRecord.ID(
				recordName: encryptedNodeId,
				zoneID: CKRecordZone.default().zoneID
			)
		)
		
		record[record_column_mnemonics] = mnemonics
		record[record_column_language] = "en"
		record[record_column_name] = "" // Todo
		
		let operation = CKModifyRecordsOperation(
			recordsToSave: [record],
			recordIDsToDelete: []
		)
		
		operation.savePolicy = .changedKeys
		
		let perRecordSaveBlock = {(recordID: CKRecord.ID, result: Result<CKRecord, Error>) -> Void in
			
			switch result {
			case .success(_):
				finish(.success)
			case .failure(let error):
				finish(.failure(error))
			}
		}
		
		if #available(iOS 15.0, *) {
			operation.perRecordSaveBlock = perRecordSaveBlock
		} else {
			operation.perRecordCompletionBlock = {(record: CKRecord, error: Error?) -> Void in
				if let error = error {
					perRecordSaveBlock(record.recordID, Result.failure(error))
				} else {
					perRecordSaveBlock(record.recordID, Result.success(record))
				}
			}
		}
		
		let configuration = CKOperation.Configuration()
		configuration.allowsCellularAccess = true
		operation.configuration = configuration
		
		CKContainer.default().privateCloudDatabase.add(operation)
	}
	
	private func deleteSeed() {
		log.trace("deleteSeed()")
		
		let finish = { (result: Result<Void, Error>) in
			
			switch result {
			case .success:
				log.trace("deleteSeed(): finish(): success")
				
				self.consecutiveErrorCount = 0
				self.updateState { state, deferToSimplifiedStateFlow in
					switch state.active {
						case .deleting:
							state.active = .disabled
						default:
							break
					}
				}
				
			case .failure(let error):
				log.trace("deleteSeed(): finish(): failure")
				self.handleError(error)
			}
		}
		
		// Todo: I want to test the double-upload scenario first
		finish(.success)
	}
	
	// ----------------------------------------
	// MARK: Errors
	// ----------------------------------------
	
	/// Standardized error handling routine for various async operations.
	///
	private func handleError(_ error: Error) {
		log.trace("handleError()")
		
		var isOperationCancelled = false
		var isNotAuthenticated = false
		var minDelay: Double? = nil
		
		if let ckerror = error as? CKError {
			
			switch ckerror.errorCode {
				case CKError.operationCancelled.rawValue:
					isOperationCancelled = true
				
				case CKError.notAuthenticated.rawValue:
					isNotAuthenticated = true
				
				default: break
			}
			
			// Sometimes a `notAuthenticated` error is hidden in a partial error.
			if let partialErrorsByZone = ckerror.partialErrorsByItemID {
				
				for (_, perZoneError) in partialErrorsByZone {
					if (perZoneError as NSError).code == CKError.notAuthenticated.rawValue {
						isNotAuthenticated = true
					}
				}
			}
			
			// If the error was `requestRateLimited`, then `retryAfterSeconds` may be non-nil.
			// The value may also be set for other errors, such as `zoneBusy`.
			//
			minDelay = ckerror.retryAfterSeconds
		}
		
		let useExponentialBackoff: Bool
		if isOperationCancelled || isNotAuthenticated {
			// There are edge cases to consider.
			// I've witnessed the following:
			// - CKAccountStatus is consistently reported as `.available`
			// - Attempt to create zone consistently fails with "Not Authenticated"
			//
			// This seems to be the case when, for example,
			// the account needs to accept a new "terms of service".
			//
			// After several consecutive failures, the server starts sending us a minDelay value.
			// We should interpret this as a signal to start using exponential backoff.
			//
			if let delay = minDelay, delay > 0.0 {
				useExponentialBackoff = true
			} else {
				useExponentialBackoff = false
			}
		} else {
			useExponentialBackoff = true
		}
		
		var delay = 0.0
		if useExponentialBackoff {
			self.consecutiveErrorCount += 1
			delay = self.exponentialBackoff()
		
			if let minDelay = minDelay {
				if delay < minDelay {
					delay = minDelay
				}
			}
		}
		
		updateState { state, deferToSimplifiedStateFlow in
			
			if isNotAuthenticated {
				state.waitingForCloudCredentials = true
			}
			
			switch state.active {
				case .uploading: fallthrough
				case .deleting:
					
					if useExponentialBackoff {
						state.active = .waiting_exponentialBackoff(self, delay: delay, error: error)
					} else {
						deferToSimplifiedStateFlow = true
					}
					
				default:
					break
			}
		} // </updateState>
		
		if isNotAuthenticated {
			DispatchQueue.main.async {
				self.checkForCloudCredentials()
			}
		}
	}
	
	private func exponentialBackoff() -> TimeInterval {
		
		assert(consecutiveErrorCount > 0, "Invalid state")
		
		switch consecutiveErrorCount {
			case  1 : return 250.milliseconds()
			case  2 : return 500.milliseconds()
			case  3 : return 1.seconds()
			case  4 : return 2.seconds()
			case  5 : return 4.seconds()
			case  6 : return 8.seconds()
			case  7 : return 16.seconds()
			case  8 : return 32.seconds()
			case  9 : return 64.seconds()
			case 10 : return 128.seconds()
			case 11 : return 256.seconds()
			default : return 512.seconds()
		}
	}
}
