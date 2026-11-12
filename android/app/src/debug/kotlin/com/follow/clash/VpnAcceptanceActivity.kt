package com.follow.clash

import android.app.Activity
import android.os.Bundle
import android.widget.TextView

/** Debug-only foreground host, without starting Flutter or loading its Core. */
class VpnAcceptanceActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(TextView(this).apply {
            text = "FlClash isolated VPN acceptance — test in progress"
            textSize = 18f
            setPadding(32, 48, 32, 32)
        })
    }
}
