from __future__ import annotations

import argparse
import socket
import subprocess
import sys
import time
import urllib.parse
import urllib.request

from .common import (
    ENTRYPOINT,
    WORKSPACE_HOST,
    WORKSPACE_BROWSER_DIR,
    WORKSPACE_HTML,
    WORKSPACE_LOG,
    WORKSPACE_PORT,
    open_private_log,
    read_regular_file,
)
from .store_core import active_bucket, connect
from .workspace_content import (
    export_markdown_bucket,
    image_dimensions,
    import_markdown_bucket,
    import_markdown_bucket_dialog,
    markdown_bucket,
    render_bucket_markdown,
)


def workspace_serve(_: argparse.Namespace) -> None:
    from .workspace_server import BoundedWorkspaceServer, WorkspaceHandler

    try:
        read_regular_file(WORKSPACE_HTML, root=WORKSPACE_HTML.parent, max_bytes=512 * 1024)
    except (OSError, ValueError) as error:
        raise SystemExit(f"feed-the-flock: workspace is missing or unsafe: {error}") from error
    BoundedWorkspaceServer((WORKSPACE_HOST, WORKSPACE_PORT), WorkspaceHandler).serve_forever()


def workspace_stop(_: argparse.Namespace) -> None:
    request = urllib.request.Request(
        f"http://{WORKSPACE_HOST}:{WORKSPACE_PORT}/api/shutdown",
        data=b"{}", headers={"Content-Type": "application/json"}, method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=3) as response:
            response.read(1024)
    except OSError:
        return


def workspace_bucket(args: argparse.Namespace) -> None:
    with connect() as db:
        bucket_id = args.bucket_id or active_bucket(db)
        if not db.execute("SELECT 1 FROM buckets WHERE id = ?", (bucket_id,)).fetchone():
            raise SystemExit("feed-the-flock: bucket does not exist")
    try:
        with socket.create_connection((WORKSPACE_HOST, WORKSPACE_PORT), timeout=0.2):
            pass
    except OSError:
        log = open_private_log(WORKSPACE_LOG)
        subprocess.Popen(
            [sys.executable, str(ENTRYPOINT), "_workspace-serve"],
            stdin=subprocess.DEVNULL, stdout=log, stderr=log,
            start_new_session=True, close_fds=True,
        )
        log.close()
        for _ in range(30):
            try:
                with socket.create_connection((WORKSPACE_HOST, WORKSPACE_PORT), timeout=0.2):
                    break
            except OSError:
                time.sleep(0.1)
        else:
            raise SystemExit(f"feed-the-flock: workspace did not start; see {WORKSPACE_LOG}")
    url = f"http://{WORKSPACE_HOST}:{WORKSPACE_PORT}/?bucket={urllib.parse.quote(bucket_id)}"
    WORKSPACE_BROWSER_DIR.mkdir(parents=True, exist_ok=True, mode=0o700)
    WORKSPACE_BROWSER_DIR.chmod(0o700)
    subprocess.Popen(
        [
            "omarchy-launch-webapp", url,
            f"--user-data-dir={WORKSPACE_BROWSER_DIR}",
            "--disable-extensions", "--no-first-run", "--no-default-browser-check",
        ], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL, start_new_session=True,
    )
    print(url)


def open_bucket(args: argparse.Namespace) -> None:
    with connect() as db:
        bucket_id = args.bucket_id or active_bucket(db)
        path = render_bucket_markdown(db, bucket_id)
    try:
        subprocess.Popen(
            ["omarchy-launch-editor", str(path)],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
    except OSError as error:
        raise SystemExit(f"feed-the-flock: could not open the Omarchy editor: {error}") from error
