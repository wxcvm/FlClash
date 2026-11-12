package com.follow.clash.service;

import android.os.ParcelFileDescriptor;

interface ISingBoxPreflight {
    String validate(in ParcelFileDescriptor config);
}
