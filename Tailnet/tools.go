//go:build tools

// The gomobile fork Tailnet/build.sh binds the iPhone framework with (the one Open Screen Sharing uses); its bind
// package must be in this module.
package tailnet

import _ "github.com/sagernet/gomobile/bind"
