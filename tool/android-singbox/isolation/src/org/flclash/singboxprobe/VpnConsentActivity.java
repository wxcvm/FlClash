package org.flclash.singboxprobe;

import android.app.Activity;
import android.content.Intent;
import android.net.VpnService;
import android.os.Bundle;

public final class VpnConsentActivity extends Activity {
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        Intent consent = VpnService.prepare(this);
        if (consent == null) finish();
        else startActivityForResult(consent, 1);
    }

    @Override protected void onActivityResult(int request, int result, Intent data) {
        super.onActivityResult(request, result, data);
        finish();
    }
}
