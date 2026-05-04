"""Tailscale-identity-headers auth middleware.

When the app is reached via `tailscale serve --identity-headers`,
Tailscale populates the following request headers with the verified
identity of the calling tailnet member:

  Tailscale-User-Login   the user's email (or login name)
  Tailscale-User-Name    the user's display name
  Tailscale-User-Profile-Pic
  Tailscale-Tailnet       the tailnet name

We trust those headers because the only ingress path to this app is
`tailscale serve` → `127.0.0.1:8080`. Direct LAN access to 127.0.0.1
on this host means the operator is already on the box, in which case
the web UI is not the access-control surface (their shell account is).

If the headers are missing — meaning someone reached `127.0.0.1:8080`
without going through Tailscale serve, or Tailscale was misconfigured
— we refuse to serve the request.
"""

from functools import wraps
from flask import g, request, abort


HEADER_LOGIN = "Tailscale-User-Login"
HEADER_NAME = "Tailscale-User-Name"
HEADER_TAILNET = "Tailscale-Tailnet"


def require_tailscale_identity(view):
    @wraps(view)
    def wrapper(*args, **kwargs):
        login = request.headers.get(HEADER_LOGIN)
        if not login:
            abort(
                403,
                "This UI is reachable only via the host's Tailscale "
                "tailnet. The Tailscale-User-Login identity header was "
                "missing from this request.",
            )
        g.user_login = login
        g.user_name = request.headers.get(HEADER_NAME, login)
        g.tailnet = request.headers.get(HEADER_TAILNET, "")
        return view(*args, **kwargs)

    return wrapper
