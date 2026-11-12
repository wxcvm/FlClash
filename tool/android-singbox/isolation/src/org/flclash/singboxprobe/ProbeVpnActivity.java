package org.flclash.singboxprobe;

import android.app.Activity;
import android.content.Intent;
import android.net.VpnService;
import android.os.Bundle;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.TextView;

/** Manual consent is required; installing the diagnostic never starts a VPN. */
public final class ProbeVpnActivity extends Activity {
    private static final int CONSENT = 1;
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        LinearLayout layout = new LinearLayout(this);
        layout.setOrientation(LinearLayout.VERTICAL);
        int padding = (int) (24 * getResources().getDisplayMetrics().density);
        layout.setPadding(padding, padding, padding, padding);
        TextView description = new TextView(this);
        description.setText("FlClash sing-box diagnostic\n\n"
            + "Stop your existing VPN before testing: Android permits one active VPN. "
            + "This test routes only this diagnostic app's traffic to 1.1.1.1; "
            + "it does not use your FlClash profiles or start automatically.");
        layout.addView(description);
        Button start = new Button(this);
        start.setText("Authorize and start diagnostic VPN");
        start.setOnClickListener(view -> {
            Intent permission = VpnService.prepare(this);
            if (permission != null) startActivityForResult(permission, CONSENT);
            else startProbe();
        });
        layout.addView(start);
        Button stop = new Button(this);
        stop.setText("Stop diagnostic VPN");
        stop.setOnClickListener(view -> stopService(new Intent(this, ProbeVpnService.class)));
        layout.addView(stop);
        setContentView(layout);
    }

    private void startProbe() {
        startForegroundService(new Intent(this, ProbeVpnService.class));
    }

    @Override protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        if (requestCode == CONSENT && resultCode == RESULT_OK) startProbe();
    }
}
