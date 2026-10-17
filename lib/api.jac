"""Helpers around the server endpoints the client calls.

Endpoints are imported straight from `resqmesh.service.endpoints` and awaited like local
functions. A refused call throws; `parseError` turns the thrown value into
`{status, code, message}` where `code` is the short word the server puts in front of its
message (`unauthorized`, `forbidden`, `not_found`, `conflict`, `invalid`) and `message` is
the sentence a person should read.

Two behaviours to know about:

* Reader endpoints are cached by the client runtime for 60 seconds. The two that are
  polled (`get_incident`, `public_alerts`) take a `nonce`; pass a number that changes on
  every poll and the cache is bypassed.
* A successful sign-in or sign-out clears that cache, and so does any write.
"""

import from "@mantine/notifications" { notifications }

glob CODE_STATUS: dict[str, int] = {
    "unauthorized": 401, "forbidden": 403, "not_found": 404, "conflict": 409, "invalid": 422
};

"""The refusal inside a thrown endpoint error, as {status, code, message}."""
def:pub parseError(e: any) -> dict[str, any] {
    status: any = 0;
    message: any = "The request failed.";
    code: str = "";
    detail: any = "";
    body: any = None;
    if e and e.status {
        status = e.status;
    }
    if e and e.detail {
        detail = str(e.detail);
    } elif e and e.message {
        detail = str(e.message);
    }
    start: int = detail.find("{");
    if start >= 0 {
        try {
            body = JSON.parse(detail[start:]);
            if body and body.error and body.error.message {
                message = str(body.error.message);
            }
        } except Exception {
            message = detail;
        }
    } elif detail {
        message = detail;
    }
    cut: int = message.find(": ");
    if cut > 0 and cut < 14 {
        word: str = message[:cut];
        if word in CODE_STATUS {
            code = word;
            message = message[cut + 2:];
            status = CODE_STATUS[word];
        }
    }
    return {"status": status, "code": code, "message": message};
}

"""The sentence to show for a thrown endpoint error."""
def:pub errorText(e: any) -> str {
    return parseError(e)["message"];
}

"""True when the server said this session is missing or no longer valid."""
def:pub isUnauthorized(e: any) -> bool {
    err = parseError(e);
    return err["status"] == 401 or err["code"] == "unauthorized";
}

"""Toast a failure."""
def:pub notifyError(e: any, title: str = "That did not work") -> None {
    notifications.show({"title": title, "message": errorText(e), "color": "red"});
}

"""Toast a success or an acknowledgement."""
def:pub notifyOk(message: str, title: str = "Done") -> None {
    notifications.show({"title": title, "message": message, "color": "teal"});
}
