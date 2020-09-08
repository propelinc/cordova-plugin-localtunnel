package com.propel.localtunnel

import android.app.Dialog
import android.content.Context

/**
 * Created by Oliver on 22/11/2013.
 */
class LocalTunnelDialog(var _context: Context, theme: Int) : Dialog(_context, theme) {
    var _localTunnel: LocalTunnel? = null
    fun setLocalTunnel(browser: LocalTunnel?) {
        _localTunnel = browser
    }

    override fun onBackPressed() {
        val lt = _localTunnel
        if (lt == null) {
            dismiss()
        } else {
            // better to go through the in localTunnel
            // because it does a clean up
            if (lt.hardwareBack() && lt.canGoBack()) {
                lt.goBack()
            } else {
                lt.closeDialog()
            }
        }
    }
}