package com.follow.clash.service;

import android.os.ParcelFileDescriptor;
import com.follow.clash.service.ISingBoxVpnEvents;

interface ISingBoxVpn {
    String prepare(in ParcelFileDescriptor config, ISingBoxVpnEvents events);
    String state(IBinder owner);
    void startVpn(IBinder owner);
    void stopVpn(IBinder owner);
}
