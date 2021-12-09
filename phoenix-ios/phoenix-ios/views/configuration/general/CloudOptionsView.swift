import SwiftUI
import CloudKit
import CircularCheckmarkProgress
import os.log

#if DEBUG && true
fileprivate var log = Logger(
	subsystem: Bundle.main.bundleIdentifier!,
	category: "CloudOptionsView"
)
#else
fileprivate var log = Logger(OSLog.disabled)
#endif

extension VerticalAlignment {
	private enum CenterTopLineAlignment: AlignmentID {
		static func defaultValue(in d: ViewDimensions) -> CGFloat {
			return d[.bottom]
		}
	}
	
	static let centerTopLine = VerticalAlignment(CenterTopLineAlignment.self)
}

struct CloudOptionsView: View {
	
	var body: some View {
		
		List {
			Section_BackupSeed()
			Section_BackupTransactions()
		}
		.listStyle(.insetGrouped)
		.navigationTitle("Cloud Backup")
	}
}

fileprivate struct Section_BackupSeed: View {
	
	@State var backupSeed_enabled = Prefs.shared.backupSeed_isEnabled
	
	@State var syncState: SyncSeedManager_State = .initializing
	let syncSeedManager = AppDelegate.get().syncSeedManager!
	
	@ViewBuilder
	var body: some View {
		
		Section(header: Text("Recovery Phrase")) {
			
			NavigationLink(destination: EmptyView()) {
				HStack(alignment: VerticalAlignment.center, spacing: 0) {
					Label("Manual backup", systemImage: "squareshape.split.3x3")
					Spacer()
					Image(systemName: "checkmark")
						.font(Font.body.weight(Font.Weight.heavy))
						.foregroundColor(Color.appAccent)
						.isHidden(backupSeed_enabled == true)
				}
			}
			NavigationLink(destination: CloudBackupAgreement(backupSeed_enabled: $backupSeed_enabled)) {
				HStack(alignment: VerticalAlignment.center, spacing: 0) {
					Label("iCloud backup", systemImage: "icloud")
					Spacer()
					Image(systemName: "checkmark")
						.foregroundColor(Color.appAccent)
						.font(Font.body.weight(Font.Weight.heavy))
						.isHidden(backupSeed_enabled == false)
				}
			}
			
			// Implicit divider added here
			
			status()
				.padding(.vertical, 10)
			
		} // </Section>
		.onChange(of: backupSeed_enabled) { newValue in
			didToggle_backupSeed_enabled(newValue)
		}
		.onReceive(syncSeedManager.statePublisher) {
			syncStateChanged($0)
		}
	}
	
	@ViewBuilder
	func status() -> some View {
		
		if backupSeed_enabled {
			
			if syncState == .synced {
				status_uploaded()
			} else {
				status_syncState()
			}
			
		} else {
			
			if syncState == .disabled {
				status_manual()
			} else {
				status_syncState()
			}
		}
	}
	
	@ViewBuilder
	func status_uploaded() -> some View {
		
		VStack(alignment: HorizontalAlignment.leading, spacing: 0) {
			
			Label {
				VStack(alignment: HorizontalAlignment.leading, spacing: 10) {
					Text("Your recovery phrase is stored in iCloud.")
					
					Text(
						"""
						Phoenix can restore your funds automatically.
						"""
					)
					.foregroundColor(Color.gray)
				}
			} icon: {
				Image(systemName: "externaldrive.badge.checkmark")
					.renderingMode(.template)
					.imageScale(.medium)
			}
		}
	}
	
	@ViewBuilder
	func status_manual() -> some View {
		
		VStack(alignment: HorizontalAlignment.leading, spacing: 0) {
			
			Label {
				VStack(alignment: HorizontalAlignment.leading, spacing: 10) {
					Text("You are responsible for backing up your recovery phrase.")
					
					Text(
						"""
						If done correctly, self-backup is the most secure option.
						"""
					)
					.foregroundColor(Color.gray)
				}
			} icon: {
				Image(systemName: "rectangle.and.pencil.and.ellipsis")
					.renderingMode(.template)
					.imageScale(.medium)
			}
		}
	}
	
	@ViewBuilder
	func status_syncState() -> some View {
		
		VStack(alignment: HorizontalAlignment.leading, spacing: 20) {
			
			if backupSeed_enabled {
				Label {
					Text("Uploading your recovery phrase to iCloud…")
				} icon: {
					Image(systemName: "externaldrive.badge.plus")
						.renderingMode(.template)
						.imageScale(.medium)
				}
			} else {
				Label {
					Text("Deleting your recovery phrase from iCloud…")
				} icon: {
					Image(systemName: "externaldrive.badge.minus")
						.renderingMode(.template)
						.imageScale(.medium)
				}
			}
			
			if syncState == .uploading {
				Label {
					Text("Sending…")
				} icon: {
					ProgressView()
						.progressViewStyle(CircularProgressViewStyle(tint: Color.appAccent))
				}
				
			} else if syncState == .deleting {
				Label {
					Text("Deleting…")
				} icon: {
					ProgressView()
						.progressViewStyle(CircularProgressViewStyle(tint: Color.appAccent))
				}
				
			} else if case .waiting(let details) = syncState  {
				
				switch details.kind {
				case .forInternet:
					Label {
						Text("Waiting for internet…")
					} icon: {
						ProgressView()
							.progressViewStyle(CircularProgressViewStyle(tint: Color.appAccent))
					}
					
				case .forCloudCredentials:
					Label {
						Text("Please sign into iCloud")
					} icon: {
						Image(systemName: "exclamationmark.triangle.fill")
							.renderingMode(.template)
							.foregroundColor(Color.appWarn)
					}
					
				case .exponentialBackoff(let error):
					SyncErrorDetails(waiting: details, error: error)
					
				} // </switch>
			} // </case .waiting>
		} // </VStack>
	}
	
	func didToggle_backupSeed_enabled(_ flag: Bool) {
		log.trace("didToggle_backupSeed_enabled(newValue = \(flag))")
		
		Prefs.shared.backupSeed_isEnabled = flag
	}
	
	func syncStateChanged(_ newSyncState: SyncSeedManager_State) {
		log.trace("syncStateChanged()")
		
		syncState = newSyncState
	}
}

fileprivate struct Section_BackupTransactions: View, ViewName {
	
	@State var backupTransactions_enabled = Prefs.shared.backupTransactions_isEnabled
	@State var backupTransactions_useCellularData = Prefs.shared.backupTransactions_useCellular
	@State var backupTransactions_useUploadDelay = Prefs.shared.backupTransactions_useUploadDelay
	
	@ViewBuilder
	var body: some View {
		
		Section(header: Text("Transactions")) {
			
			Toggle(isOn: $backupTransactions_enabled) {
				Label("iCloud backup", systemImage: "icloud")
			}
			
			// Implicit divider added here
			
			VStack(alignment: HorizontalAlignment.leading, spacing: 0) {
				statusLabel()
					.padding(.top, 5)
				
				if backupTransactions_enabled {
					cellularDataOption()
						.padding(.top, 30)
					
					uploadDelaysOption()
						.padding(.top, 20)
				}
			} // </VStack>
			.padding(.vertical, 10)
			
		} // </Section>
		.onChange(of: backupTransactions_enabled) { newValue in
			didToggle_backupTransactions_enabled(newValue)
		}
		.onChange(of: backupTransactions_useCellularData) { newValue in
			didToggle_backupTransactions_useCellularData(newValue)
		}
		.onChange(of: backupTransactions_useUploadDelay) { newValue in
			didToggle_backupTransactions_useUploadDelay(newValue)
		}
	}
	
	@ViewBuilder
	func statusLabel() -> some View {
		
		if backupTransactions_enabled {
			
			Label {
				VStack(alignment: HorizontalAlignment.leading, spacing: 10) {
					Text("Your payment history will be stored in iCloud.")
					
					Text(
						"""
						The data stored in the cloud is encrypted, \
						and can only be decrypted with your seed.
						"""
					)
					.foregroundColor(Color.gray)
				}
			} icon: {
				Image(systemName: "externaldrive.badge.icloud")
					.renderingMode(.template)
					.imageScale(.medium)
					.foregroundColor(Color.appAccent)
			}
			
		} else {
			
			Label {
				VStack(alignment: HorizontalAlignment.leading, spacing: 10) {
					Text("Your payment history is only stored on this device.")
					
					Text(
						"""
						If you switch to a new device (or reinstall the app) \
						then you'll lose your payment history.
						"""
					)
					.foregroundColor(Color.gray)
				}
			} icon: {
				Image(systemName: "internaldrive")
					.renderingMode(.template)
					.imageScale(.medium)
					.foregroundColor(Color.appWarn)
			}
		}
	}
	
	@ViewBuilder
	func cellularDataOption() -> some View {
		
		// alignmentGuide explanation:
		//
		// The Toggle wants to vertically align its switch in the center of the body:
		//
		// |body| |switch|
		//
		// This works good when the body is a single line.
		// But with multiple lines it looks like:
		//
		// |line1|
		// |line2| |switch|
		// |line3|
		//
		// This isn't what we want.
		// So we use a custom VerticalAlignment to achieve our desired result.
		//
		// Here's how it works:
		// - The toggle queries its body for the VerticalAlignment.center value
		// - Our body is our Label
		// - So in `Step A` below, we override the Label's VerticalAlignment.center value to
		//   return instead the VerticalAlignment.centerTopLine value
		// - And in `Step B` below, we provide the value for VerticalAlignment.centerTopLine.
		//
		// A good resource on alignment guides can be found here:
		// https://swiftui-lab.com/alignment-guides/
		
		Toggle(isOn: $backupTransactions_useCellularData) {
			Label {
				VStack(alignment: HorizontalAlignment.leading, spacing: 8) {
					HStack(alignment: VerticalAlignment.firstTextBaseline, spacing: 0) {
						Text("Use cellular data")
					}
					.alignmentGuide(VerticalAlignment.centerTopLine) { (d: ViewDimensions) in
						d[VerticalAlignment.center] // Step B
					}
					
					let explanation = backupTransactions_useCellularData ?
						NSLocalizedString(
							"Uploads can occur over cellular connections.",
							comment: "Explanation for 'Use cellular data' toggle"
						) :
						NSLocalizedString(
							"Uploads will only occur over WiFi.",
							comment: "Explanation for 'Use cellular data' toggle"
						)
					
					Text(explanation)
						.lineLimit(nil) // text is getting truncated for some reason
						.font(.callout)
						.foregroundColor(Color.secondary)
				}
			} icon: {
				Image(systemName: "network")
					.renderingMode(.template)
					.imageScale(.medium)
					.foregroundColor(Color.appAccent)
			} // </Label>
			.alignmentGuide(VerticalAlignment.center) { d in
				d[VerticalAlignment.centerTopLine] // Step A
			}
		} // </Toggle>
	}
	
	@ViewBuilder
	func uploadDelaysOption() -> some View {
		
		Toggle(isOn: $backupTransactions_useUploadDelay) {
			Label {
				VStack(alignment: HorizontalAlignment.leading, spacing: 8) {
					Text("Randomize upload delays")
					.alignmentGuide(VerticalAlignment.centerTopLine) { (d: ViewDimensions) in
						d[VerticalAlignment.center]
					}
					
					let explanation = backupTransactions_useUploadDelay ?
						NSLocalizedString(
							"Avoids payment correlation using timestamp metadata.",
							comment: "Explanation for 'Randomize upload delays' toggle"
						) :
						NSLocalizedString(
							"Payments are uploaded to the cloud immediately upon completion.",
							comment: "Explanation for 'Randomize upload delays' toggle"
						)
					
					Text(explanation)
						.lineLimit(nil) // text is getting truncated for some reason
						.font(.callout)
						.foregroundColor(Color.secondary)
						
				}
			} icon: {
				Image(systemName: "timer")
					.renderingMode(.template)
					.imageScale(.medium)
					.foregroundColor(Color.appAccent)
			}
			.alignmentGuide(VerticalAlignment.center) { d in
				d[VerticalAlignment.centerTopLine]
			}
		}
	}
	
	func didToggle_backupTransactions_enabled(_ flag: Bool) {
		log.trace("didToggle_backupTransactions_enabled(newValue = \(flag))")
		
		Prefs.shared.backupTransactions_isEnabled = flag
	}
	
	func didToggle_backupTransactions_useCellularData(_ flag: Bool) {
		log.trace("didToggle_backupTransactions_useCellularData(newValue = \(flag))")
		
		Prefs.shared.backupTransactions_useCellular = flag
	}
	
	func didToggle_backupTransactions_useUploadDelay(_ flag: Bool) {
		log.trace("didToggle_backupTransactions_useUploadDelay(newValue = \(flag))")
		
		Prefs.shared.backupTransactions_useUploadDelay = flag
	}
}

fileprivate struct SyncErrorDetails: View, ViewName {
	
	let waiting: SyncSeedManager_State_Waiting
	let error: Error
	
	let timer = Timer.publish(every: 0.5, on: .current, in: .common).autoconnect()
	@State var currentDate = Date()
	
	@ViewBuilder
	var body: some View {
		
		VStack(alignment: HorizontalAlignment.leading, spacing: 4) {
			HStack(alignment: VerticalAlignment.center, spacing: 4) {
				Image(systemName: "exclamationmark.triangle.fill")
					.renderingMode(.template)
					.foregroundColor(Color.appWarn)
				
				Text("Error - retry in:")
			}
			
			HStack(alignment: VerticalAlignment.center, spacing: 8) {
				
				let (progress, remaining, total) = progressInfo()
				
				ProgressView(value: progress, total: 1.0)
					.progressViewStyle(CircularCheckmarkProgressViewStyle(
						strokeStyle: StrokeStyle(lineWidth: 3.0),
						showGuidingLine: true,
						guidingLineWidth: 1.0,
						showPercentage: false,
						checkmarkAnimation: .trim
					))
					.foregroundColor(Color.appAccent)
					.frame(maxWidth: 20, maxHeight: 20)
				
				Text(verbatim: "\(remaining) / \(total)")
					.font(.system(.callout, design: .monospaced))
				
				Spacer()
				
				Button {
					skipButtonTapped()
				} label: {
					HStack(alignment: VerticalAlignment.center, spacing: 4) {
						Text("Skip")
						Image(systemName: "arrowshape.turn.up.forward")
							.imageScale(.medium)
					}
				}
			}
			.padding(.top, 4)
			.padding(.bottom, 4)
			
			if let errorInfo = errorInfo() {
				Text(errorInfo)
					.font(.callout)
					.multilineTextAlignment(.leading)
					.lineLimit(2)
			}
		} // </VStack>
		.onReceive(timer) { _ in
			self.currentDate = Date()
		}
	}
	
	func progressInfo() -> (Double, String, String) {
		
		guard let until = waiting.until else {
			return (1.0, "0:00", "0:00")
		}
		
		let start = until.startDate.timeIntervalSince1970
		let end = until.fireDate.timeIntervalSince1970
		let now = currentDate.timeIntervalSince1970
		
		guard start < end, now >= start, now < end else {
			return (1.0, "0:00", "0:00")
		}
		
		let progressFraction = (now - start) / (end - start)
		
		let remaining = formatTimeInterval(end - now)
		let total = formatTimeInterval(until.delay)
		
		return (progressFraction, remaining, total)
	}
	
	func formatTimeInterval(_ value: TimeInterval) -> String {
		
		let minutes = Int(value) / 60
		let seconds = Int(value) % 60
		
		return String(format: "%d:%02d", minutes, seconds)
	}
	
	func errorInfo() -> String? {
		
		guard case .exponentialBackoff(let error) = waiting.kind else {
			return nil
		}
		
		var result: String? = nil
		if let ckerror = error as? CKError {
			
			switch ckerror.errorCode {
				case CKError.quotaExceeded.rawValue:
					result = "iCloud storage is full"
				
				default: break
			}
		}
		
		return result ?? error.localizedDescription
	}
	
	func skipButtonTapped() -> Void {
		log.trace("[\(viewName)] skipButtonTapped()")
		
		waiting.skip()
	}
}

fileprivate struct CloudBackupAgreement: View, ViewName {
	
	@Binding var backupSeed_enabled: Bool
	
	@State var toggle_enabled: Bool
	
	@State var legal_appleRisk: Bool
	@State var legal_governmentRisk: Bool
	
	@State var animatingLegalToggleColor = false
	
	var canSave: Bool {
		if backupSeed_enabled {
			// Currently enabled.
			// To disable, user only needs to disable the toggle
			return !toggle_enabled
		} else {
			// Currently disabled.
			// To enable, user must enable the toggle, and accept the legal risks.
			return toggle_enabled && legal_appleRisk && legal_governmentRisk
		}
	}
	
	@Environment(\.presentationMode) var presentationMode: Binding<PresentationMode>
	
	init(backupSeed_enabled: Binding<Bool>) {
		self._backupSeed_enabled = backupSeed_enabled
		let enabled = backupSeed_enabled.wrappedValue
		
		self._toggle_enabled = State<Bool>(initialValue: enabled)
		self._legal_appleRisk = State<Bool>(initialValue: enabled)
		self._legal_governmentRisk = State<Bool>(initialValue: enabled)
	}
	
	@ViewBuilder
	var body: some View {
		
		List {
			section_toggle()
			section_legal()
		}
		.navigationTitle("iCloud Backup")
		.navigationBarBackButtonHidden(true)
		.navigationBarItems(leading: backButton())
	}
	
	@ViewBuilder
	func backButton() -> some View {
		
		Button {
			didTapBackButton()
		} label: {
			HStack(alignment: VerticalAlignment.center, spacing: 0) {
				Image(systemName: "chevron.left")
					 .font(.title2)
				if canSave {
					Text("Save")
				} else {
					Text("Cancel")
				}
			}
		}
	}
	
	@ViewBuilder
	func section_toggle() -> some View {
		
		Section {
			Toggle(isOn: $toggle_enabled) {
				Label("Enable iCloud backup", systemImage: "icloud")
			}
			.padding(.bottom, 5)
			
			// Implicit divider added here
			
			VStack(alignment: HorizontalAlignment.leading, spacing: 0) {
				Label {
					Text(
						"""
						Your recovery phrase will be stored in iCloud, \
						and Phoenix can automatically restore your wallet balance.
						"""
					)
				} icon: {
					Image(systemName: "lightbulb")
				}
			}
			.padding(.vertical, 10)
		}
	}
	
	@ViewBuilder
	func section_legal() -> some View {
		
		Section {
			
			Toggle(isOn: $legal_appleRisk) {
				Text(
					"""
					I understand that certain Apple employees may be able \
					to access my iCloud data.
					"""
				)
				.lineLimit(nil)
				.alignmentGuide(VerticalAlignment.center) { d in
					d[VerticalAlignment.firstTextBaseline]
				}
			}
			.toggleStyle(CheckboxToggleStyle(
				onImage: onImage(),
				offImage: offImage()
			))
			.padding(.vertical, 5)
			
			Toggle(isOn: $legal_governmentRisk) {
				Text(
					"""
					I understand that Apple may share my iCloud data \
					with government agencies upon request.
					"""
				)
				.lineLimit(nil)
				.alignmentGuide(VerticalAlignment.center) { d in
					d[VerticalAlignment.firstTextBaseline]
				}
			}
			.toggleStyle(CheckboxToggleStyle(
				onImage: onImage(),
				offImage: offImage()
			))
			.padding(.vertical, 5)
			
		} header: {
			Text("Legal")
			
		} // </Section>
		.onChange(of: toggle_enabled) { newValue in
			didToggleEnabled(newValue)
		}
	}
	
	@ViewBuilder
	func onImage() -> some View {
		Image(systemName: "checkmark.square.fill")
			.imageScale(.large)
	}
	
	@ViewBuilder
	func offImage() -> some View {
		if toggle_enabled {
			Image(systemName: "square")
				.renderingMode(.template)
				.imageScale(.large)
				.foregroundColor(animatingLegalToggleColor ? Color.red : Color.primary)
		} else {
			Image(systemName: "square")
				.imageScale(.large)
		}
	}
	
	func didToggleEnabled(_ value: Bool) {
		log.trace("[\(viewName)] didToggleEnabled")
		
		if value {
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
				if toggle_enabled {
					withAnimation(Animation.linear(duration: 0.5).repeatForever(autoreverses: true)) {
						animatingLegalToggleColor = true
					}
				}
			}
		} else {
			animatingLegalToggleColor = false
		}
	}
	
	func didTapBackButton() {
		log.trace("[\(viewName)] didTapBackButton()")
		
		if canSave {
			backupSeed_enabled = toggle_enabled
		}
		presentationMode.wrappedValue.dismiss()
	}
}
