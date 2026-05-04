"""OSR host admin UI.

Served on 127.0.0.1:8080 by gunicorn under systemd, exposed onto the
tailnet by `tailscale serve`. See docs/host-ui-plan.md for the
architectural rationale and host-ui/README.md for deployment.
"""

from flask import Flask, g, render_template, request

from auth import require_tailscale_identity
from status import status_snapshot, tail_log, classify_log_line, HOST_LOG
import whitelist as wl


app = Flask(__name__)


@app.context_processor
def inject_user_into_templates():
    """Make the authenticated tailnet user visible in the layout header."""
    return {
        "current_user": getattr(g, "user_name", None),
        "current_login": getattr(g, "user_login", None),
        "current_tailnet": getattr(g, "tailnet", None),
    }


@app.route("/")
@require_tailscale_identity
def status():
    snapshot = status_snapshot()
    return render_template("status.html", snapshot=snapshot)


@app.route("/whitelist", methods=["GET"])
@require_tailscale_identity
def whitelist_view():
    text = wl.read_whitelist()
    return render_template(
        "whitelist.html",
        whitelist_text=text,
        path=str(wl.WHITELIST_PATH),
        errors=[],
        warnings=[],
        saved=False,
    )


@app.route("/whitelist", methods=["POST"])
@require_tailscale_identity
def whitelist_save():
    text = request.form.get("whitelist", "")
    errors, warnings = wl.validate_whitelist(text)
    saved = False
    if not errors:
        try:
            wl.write_whitelist(text)
            saved = True
        except OSError as e:
            errors.append(f"Could not save: {e}")
    return render_template(
        "whitelist.html",
        whitelist_text=text,
        path=str(wl.WHITELIST_PATH),
        errors=errors,
        warnings=warnings,
        saved=saved,
    )


@app.route("/log")
@require_tailscale_identity
def log_view():
    try:
        n = max(50, min(int(request.args.get("n", 500)), 5000))
    except ValueError:
        n = 500
    raw_lines = tail_log(HOST_LOG, n=n)
    lines = [(line, classify_log_line(line)) for line in raw_lines]
    return render_template(
        "log.html",
        lines=lines,
        n=n,
        path=str(HOST_LOG),
    )


@app.errorhandler(403)
def forbidden(e):
    return (
        render_template("error.html", code=403, description=str(e.description)),
        403,
    )


if __name__ == "__main__":
    # Local development only. Production uses gunicorn (see osr-ui.service).
    # Auth always requires the Tailscale identity headers; for dev, send them
    # explicitly with curl, e.g.
    #   curl -H 'Tailscale-User-Login: you@example.com' http://127.0.0.1:8080/
    app.run(host="127.0.0.1", port=8080, debug=True)
