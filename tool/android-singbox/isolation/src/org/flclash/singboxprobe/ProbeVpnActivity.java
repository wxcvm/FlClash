package org.flclash.singboxprobe;

import android.app.Activity;
import android.content.Intent;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.IntentFilter;
import android.os.Build;
import android.net.VpnService;
import android.os.Bundle;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.TextView;

/** Manual consent is required; installing the diagnostic never starts a VPN. */
public final class ProbeVpnActivity extends Activity {
    private static final int CONSENT = 1;
    private TextView status;
    private final BroadcastReceiver receiver = new BroadcastReceiver() {
        @Override public void onReceive(Context context, Intent intent) {
            String message = intent.getStringExtra("message");
            if (message != null) status.setText(message);
        }
    };

    @Override protected void onStart() {
        super.onStart();
        IntentFilter filter = new IntentFilter(ProbeVpnService.STATUS);
        if (Build.VERSION.SDK_INT >= 33) {
            registerReceiver(receiver, filter, ProbeVpnService.STATUS_PERMISSION, null, Context.RECEIVER_NOT_EXPORTED);
        } else {
            registerReceiver(receiver, filter, ProbeVpnService.STATUS_PERMISSION, null);
        }
    }

    @Override protected void onStop() {
        unregisterReceiver(receiver);
        super.onStop();
    }
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        LinearLayout layout = new LinearLayout(this);
        layout.setOrientation(LinearLayout.VERTICAL);
        int padding = (int) (24 * getResources().getDisplayMetrics().density);
        layout.setPadding(padding, padding, padding, padding);
        TextView description = new TextView(this);
        description.setText("FlClash sing-box diagnostic\n\n"
            + "Stop your existing VPN before testing: Android permits one active VPN. "
            + "This test routes only this diagnostic app's HTTPS and DNS test traffic; "
            + "it does not use your FlClash profiles or start automatically.");
        layout.addView(description);
        status = new TextView(this);
        status.setText("Ready. Results appear here while the diagnostic is open.");
        status.setTextIsSelectable(true);
        layout.addView(status);
        Button start = new Button(this);
        start.setText("Authorize and start diagnostic VPN");
        start.setOnClickListener(view -> {
            Intent permission = VpnService.prepare(this);
            if (permission != null) startActivityForResult(permission, CONSENT);
            else startProbe();
        });
        layout.addView(start);
        Button retest = new Button(this);
        retest.setText("Retest traffic after network change");
        retest.setOnClickListener(view -> startService(
            new Intent(this, ProbeVpnService.class).setAction(ProbeVpnService.RETEST)));
        layout.addView(retest);
        Button stop = new Button(this);
        stop.setText("Stop diagnostic VPN");
        stop.setOnClickListener(view -> stopService(new Intent(this, ProbeVpnService.class)));
        layout.addView(stop);
        setContentView(layout);
    }

    private void startProbe() {
        status.setText("Starting diagnostic VPN...");
        startForegroundService(new Intent(this, ProbeVpnService.class));
    }

    @Override protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        if (requestCode == CONSENT && resultCode == RESULT_OK) startProbe();
    }
}
