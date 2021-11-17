package fr.acinq.phoenix.android.workshop

import android.Manifest
import android.os.Bundle
import androidx.activity.compose.setContent
import androidx.appcompat.app.AppCompatActivity
import androidx.compose.material.ExperimentalMaterialApi
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.collectAsState
import androidx.compose.ui.platform.LocalContext
import androidx.core.app.ActivityCompat
import fr.acinq.phoenix.android.*
import fr.acinq.phoenix.android.utils.Prefs
import fr.acinq.phoenix.data.BitcoinUnit
import fr.acinq.phoenix.data.FiatCurrency

class WorkshopActivity : AppCompatActivity() {

    @ExperimentalMaterialApi
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        ActivityCompat.requestPermissions(
            this@WorkshopActivity,
            arrayOf(Manifest.permission.CAMERA),
            1234
        )
        setContent {
            PhoenixAndroidTheme {
                val fiatRates = fr.acinq.phoenix.android.application.business.currencyManager.ratesFlow.collectAsState(listOf())
                val context = LocalContext.current
                val isAmountInFiat = Prefs.getIsAmountInFiat(context).collectAsState(false)
                val fiatCurrency = Prefs.getFiatCurrency(context).collectAsState(initial = FiatCurrency.USD)
                val bitcoinUnit = Prefs.getBitcoinUnit(context).collectAsState(initial = BitcoinUnit.Sat)
                val electrumServer = Prefs.getElectrumServer(context).collectAsState(initial = null)

                CompositionLocalProvider(
                    LocalBusiness provides fr.acinq.phoenix.android.application.business,
                    LocalControllerFactory provides fr.acinq.phoenix.android.application.business.controllers,
                    LocalExchangeRates provides fiatRates.value,
                    LocalBitcoinUnit provides bitcoinUnit.value,
                    LocalFiatCurrency provides fiatCurrency.value,
                    LocalShowInFiat provides isAmountInFiat.value,
                    LocalElectrumServer provides electrumServer.value
                ) {
                    WorkshopView()
                }
            }
        }
    }
}