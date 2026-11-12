package core

import "testing"

func TestDownloadSpeedRate(t *testing.T) {
	tests := []struct {
		bytes  int64
		millis int64
		want   int64
	}{
		{0, 1000, 0},
		{1024 * 1024, 1000, 1024 * 1024},
		{1024 * 1024, 2000, 512 * 1024},
		{1024, 0, 1024 * 1000},
	}
	for _, test := range tests {
		got := downloadBytesPerSecond(test.bytes, test.millis)
		if got != test.want {
			t.Errorf("rate(%d, %d) = %d, want %d",
				test.bytes, test.millis, got, test.want)
		}
	}
}
