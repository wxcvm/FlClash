package core

import "errors"

var errVPNProtect = errors.New("Android VPN refused outbound socket protection")

// RawConn.Control reports descriptor access errors, not whether the callback
// protected that descriptor. Return both kinds of failure to the dialer.
func protectOutboundSocket(control func(func(uintptr)) error, protect func(int) bool) error {
	protected := false
	if err := control(func(fd uintptr) { protected = protect(int(fd)) }); err != nil {
		return err
	}
	if !protected {
		return errVPNProtect
	}
	return nil
}
