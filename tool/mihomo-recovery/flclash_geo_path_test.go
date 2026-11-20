package constant

import (
	"os"
	"path/filepath"
	"testing"
)

func TestFlClashMMDBDoesNotOverwriteGeoIPDatFilename(t *testing.T) {
	previousName := GeoipName
	t.Cleanup(func() { GeoipName = previousName })

	dir := t.TempDir()
	for _, name := range []string{"GeoIP.dat", "GEOIP.metadb"} {
		if err := os.WriteFile(filepath.Join(dir, name), []byte("fixture"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	p := &path{homeDir: dir}

	if got := filepath.Base(p.GeoIP()); got != "GeoIP.dat" {
		t.Fatalf("GeoIP() selected %q", got)
	}
	if got := GeoipName; got != "GeoIP.dat" {
		t.Fatalf("GeoIP() published %q", got)
	}
	if got := filepath.Base(p.MMDB()); got != "GEOIP.metadb" {
		t.Fatalf("MMDB() selected %q", got)
	}
	if got := GeoipName; got != "GeoIP.dat" {
		t.Fatalf("MMDB() poisoned the GeoIP protobuf filename: %q", got)
	}
}
