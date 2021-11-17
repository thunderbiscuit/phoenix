package fr.acinq.phoenix.android.workshop

import android.content.Context
import android.widget.Toast
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.MaterialTheme
import androidx.compose.material.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import fr.acinq.bitcoin.MnemonicCode
import fr.acinq.lightning.Lightning
import fr.acinq.phoenix.PhoenixBusiness
import fr.acinq.phoenix.android.CF
import fr.acinq.phoenix.android.LocalBusiness
import fr.acinq.phoenix.android.components.FilledButton
import fr.acinq.phoenix.android.components.mvi.MVIView
import fr.acinq.phoenix.android.utils.Prefs
import fr.acinq.phoenix.android.utils.logger
import org.slf4j.Logger
import org.slf4j.LoggerFactory
import androidx.compose.runtime.*
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.sp
import fr.acinq.bitcoin.ByteVector32
import fr.acinq.bitcoin.DeterministicWallet
import fr.acinq.bitcoin.PublicKey
import fr.acinq.lightning.MilliSatoshi
import fr.acinq.lightning.crypto.LocalKeyManager
import fr.acinq.lightning.io.ReceivePayment
import fr.acinq.lightning.payment.PaymentRequest
import fr.acinq.lightning.utils.msat
import fr.acinq.lightning.utils.secure
import fr.acinq.phoenix.android.business
import fr.acinq.phoenix.android.components.AmountInput
import fr.acinq.phoenix.android.components.Dialog
import fr.acinq.phoenix.android.components.InputText
import fr.acinq.phoenix.android.monoTypo
import fr.acinq.phoenix.android.payments.QRCode
import fr.acinq.phoenix.android.utils.QRCode
import fr.acinq.phoenix.android.utils.copyToClipboard
import fr.acinq.phoenix.data.Chain
import kotlinx.coroutines.*
import kotlin.random.Random

@Composable
fun WorkshopView() {
    val log = logger("WorkshopView")
    val context = LocalContext.current
    val business = business
    val words = Prefs.getWords(context).collectAsState(initial = null).value
    val scope = rememberCoroutineScope()

    Column(
        Modifier
            .padding(24.dp)
            .verticalScroll(rememberScrollState())
    ) {
        log.debug("composition with words=$words")
        when {
            words.isNullOrEmpty() -> {
                Text("The wallet is not initialized")
                FilledButton(
                    text = "Create wallet",
                    onClick = {
                        scope.launch(Dispatchers.Main + CoroutineExceptionHandler { _, e ->
                            log.error("failed to generate words: ", e)
                            Toast.makeText(context, "Failed to generate words", Toast.LENGTH_SHORT).show()
                        }) {
                            WorkshopTodo.createWallet(context, business)
                        }
                    })
            }
            else -> {
                log.debug("moving to home view with words=$words")
                WorkshopHomeView(words)
            }
        }
    }
}

@Composable
fun WorkshopHomeView(words: List<String>) {
    val scope = rememberCoroutineScope()
    val business = business
    val context = LocalContext.current
    val log = logger("WorkshopHomeView")

    // start the node
    LaunchedEffect(key1 = words) {
        scope.launch(Dispatchers.Main + CoroutineExceptionHandler { _, e ->
            log.error("failed to start the node: ", e)
            Toast.makeText(context, "Failed to start the node", Toast.LENGTH_SHORT).show()
        }) {
            WorkshopTodo.startNode(business = business, words = words)
        }
    }

    // display the seed
    Text(text = "Wallet is initialized with the following seed:")
    Text(text = words.joinToString(" "), style = monoTypo())

    Spacer(modifier = Modifier.height(16.dp))

    // compute the node id ourselves
    var nodeId by remember { mutableStateOf("") }
    LaunchedEffect(key1 = words) {
        scope.launch(Dispatchers.Main + CoroutineExceptionHandler { _, e ->
            log.error("failed to compute the node id: ", e)
            Toast.makeText(context, "Failed to compute my node id", Toast.LENGTH_SHORT).show()
        }) {
            nodeId = WorkshopTodo.computeNodeIdMyself(words).toString()
        }
    }
    Text(text = "My node id (manually computed on the JVM)")
    Text(text = nodeId, style = monoTypo())

    Spacer(modifier = Modifier.height(16.dp))

    // let the shared KMP module compute the node id
    val nodeParams = business.nodeParamsManager.nodeParams.collectAsState()
    val nodeIdFromNativeBusiness = nodeParams.value
    Text(text = "My node id (from native business)")
    Text(text = nodeIdFromNativeBusiness?.nodeId.toString(), style = monoTypo())

    Spacer(modifier = Modifier.height(16.dp))

    val connectionManager = business.connectionsManager.connections.collectAsState()
    val electrumConnection = connectionManager.value.electrum
    val peerConnection = connectionManager.value.peer
    Text("Connection state")
    Text("Peer=$peerConnection", style = monoTypo())
    Text("Electrum=$electrumConnection", style = monoTypo())

    Spacer(modifier = Modifier.height(16.dp))

    InvoiceSection()
}

@Composable
private fun InvoiceSection() {
    val log = logger("InvoiceSection")
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    val business = business
    var invoice by remember { mutableStateOf<PaymentRequest?>(null) }
    var invoiceQRBitmap by remember { mutableStateOf<ImageBitmap?>(null) }

    Spacer(Modifier.height(16.dp))
    FilledButton(text = "Generate invoice") {
        scope.launch(Dispatchers.Main + CoroutineExceptionHandler { _, e ->
            log.error("failed to generate an invoice: ", e)
            Toast.makeText(context, "Failed to generate an invoice", Toast.LENGTH_SHORT).show()
        }) {
            invoice = WorkshopTodo.generateInvoice(business, null, "adopt21")
        }
    }
    invoice?.let {
        val rawInvoice = it.write()
        LaunchedEffect(key1 = rawInvoice) {
            scope.launch(Dispatchers.Main + CoroutineExceptionHandler { _, e ->
                log.error("failed to generate QR bitmap: ", e)
                Toast.makeText(context, "Failed to generate QR bitmap", Toast.LENGTH_SHORT).show()
            }) {
                invoiceQRBitmap = QRCode.generateBitmap(rawInvoice).asImageBitmap()
            }
        }
        Spacer(modifier = Modifier.height(16.dp))
        Text(text = rawInvoice, style = monoTypo(), maxLines = 2, overflow = TextOverflow.Ellipsis)
        Spacer(modifier = Modifier.height(16.dp))
        invoiceQRBitmap?.let { QRCode(it, Modifier.clickable { copyToClipboard(context, rawInvoice) }) }
    }
}

@Composable
fun logger(tag: String) = remember(tag) { LoggerFactory.getLogger(tag) }
