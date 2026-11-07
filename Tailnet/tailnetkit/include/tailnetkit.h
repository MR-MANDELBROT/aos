// Tailnetkit: aOS's Tailscale node for the iPhone app (Tailnet/tailnetkit/tailnetkit.go, a Go c-archive).
// Handles are > 0; functions that can fail return -1 (or NULL) and, when error is not NULL, a message the caller
// frees with tailnetkit_free. Strings the library returns are the caller's to free with tailnetkit_free.

#ifndef TAILNETKIT_H
#define TAILNETKIT_H

#ifdef __cplusplus
extern "C" {
#endif

/// A node with its state in dir (an absolute path); control_url is "" for Tailscale's coordination server.
int tailnetkit_new(char *dir, char *hostname, char *control_url, char **error);
/// Starts the node without waiting (until it is signed in, its status says NeedsLogin and carries a sign-in URL).
int tailnetkit_start(int node, char **error);
/// Tailscale's status JSON (the format of `tailscale status --json`), or NULL.
char *tailnetkit_status_json(int node, char **error);
/// A new sign-in URL (it shows in the status).
int tailnetkit_login(int node, char **error);
/// Signs out: the node leaves the tailnet.
int tailnetkit_logout(int node, char **error);
/// Stops the node; the handle is no longer valid.
void tailnetkit_close(int node);
/// A TCP connection to host:port through the tailnet, as one end of a connected socket pair (the caller owns the
/// descriptor), or -1.
int tailnetkit_dial(int node, char *host, int port, int timeout_millis, char **error);
/// Frees a string the library returned.
void tailnetkit_free(char *string);

#ifdef __cplusplus
}
#endif

#endif
