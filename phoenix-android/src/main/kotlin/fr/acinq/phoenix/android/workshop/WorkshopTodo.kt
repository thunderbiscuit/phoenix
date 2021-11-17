package fr.acinq.phoenix.android.workshop

import android.content.Context
import fr.acinq.bitcoin.ByteVector32
import fr.acinq.bitcoin.DeterministicWallet
import fr.acinq.bitcoin.MnemonicCode
import fr.acinq.bitcoin.PublicKey
import fr.acinq.lightning.Lightning
import fr.acinq.lightning.MilliSatoshi
import fr.acinq.lightning.crypto.LocalKeyManager
import fr.acinq.lightning.io.ReceivePayment
import fr.acinq.lightning.payment.PaymentRequest
import fr.acinq.lightning.utils.secure
import fr.acinq.phoenix.PhoenixBusiness
import fr.acinq.phoenix.android.utils.Prefs
import fr.acinq.phoenix.data.Chain
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ObsoleteCoroutinesApi
import org.slf4j.LoggerFactory
import kotlin.random.Random

@OptIn(ObsoleteCoroutinesApi::class)
object WorkshopTodo {
    val log = LoggerFactory.getLogger(WorkshopTodo::class.java)

    suspend fun startNode(
        business: PhoenixBusiness,
        words: List<String>
    ) {
        log.debug("start node using list of words=$words")
        val seed = business.prepWallet(words)
        log.debug("successfully prepared seed")
        business.loadWallet(seed)
        log.debug("wallet loaded")
        business.start()
        log.debug("node started")
        business.appConfigurationManager.updateElectrumConfig(null)
    }

    suspend fun createWallet(
        context: Context,
        business: PhoenixBusiness
    ) {
        // 1 - generate a random list of words using the bitcoin-kmp library

        // 2 - save words to datastore
        // Prefs.saveWords(context, words)
        log.debug("words saved to datastore in plain text")
    }

    suspend fun computeNodeIdMyself(
        words: List<String>
    ): PublicKey {
        // the seed is computed using the master key and a derivation path
        throw NotImplementedError("")
    }

    suspend fun generateInvoice(
        business: PhoenixBusiness,
        amount: MilliSatoshi?,
        description: String
    ): PaymentRequest {
        // first step is to roll a new preimage
        throw NotImplementedError()
    }
}