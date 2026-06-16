---
title: "WebRTC"
date: 2026-04-04T14:30:00-04:00
draft: false
tags: [frontend, webrtc, realtime, media, networking]
---

WebRTC is the browser stack for peer-to-peer audio, video, and data channels. The API looks like media elements and event handlers, but the system underneath includes signaling, ICE candidate gathering, NAT traversal, DTLS, SRTP, congestion control, codecs, jitter buffers, and device permissions. Practical WebRTC work is mostly about managing that state machine reliably.

The first mental model: WebRTC does not define signaling. Your app must exchange offers, answers, and ICE candidates over a separate channel such as WebSocket, HTTP polling, or your realtime backend. WebRTC uses that information to establish media and data paths.

{{< mermaid >}}
flowchart TD
  A[Peer A] -->|offer via signaling| B[Signaling server]
  B -->|offer| C[Peer B]
  C -->|answer via signaling| B
  B -->|answer| A
  A <-->|ICE candidates| B
  C <-->|ICE candidates| B
  A <-->|SRTP media / SCTP data| C
{{< /mermaid >}}

## Connection setup

A minimal call starts with local media, an `RTCPeerConnection`, tracks, and SDP exchange:

```js
const pc = new RTCPeerConnection({
  iceServers: [{ urls: "stun:stun.l.google.com:19302" }],
});

const stream = await navigator.mediaDevices.getUserMedia({ audio: true, video: true });
for (const track of stream.getTracks()) {
  pc.addTrack(track, stream);
}

pc.ontrack = (event) => {
  remoteVideo.srcObject = event.streams[0];
};

pc.onicecandidate = ({ candidate }) => {
  signaling.send({ type: "candidate", candidate });
};
```

Offer/answer exchange sets local and remote descriptions. ICE candidates may arrive before the remote description is set, so production code should queue candidates until the peer connection is ready.

## ICE, STUN, and TURN

ICE tries candidate pairs until it finds a working path. STUN helps discover public-facing addresses. TURN relays traffic when direct paths fail. A WebRTC app without TURN will work in friendly networks and fail for users behind restrictive NATs or corporate firewalls.

TURN is not optional for serious production use. It adds bandwidth cost, but it is the reliability fallback. Monitor how often sessions use relay candidates; a high relay rate affects cost and may reveal network environments where direct connectivity is failing.

## Media lifecycle

Stopping a call means more than closing UI. Stop local tracks, close the peer connection, detach media elements, and unregister signaling handlers.

```js
function endCall({ pc, localStream, remoteVideo }) {
  for (const sender of pc.getSenders()) {
    sender.track?.stop();
  }
  for (const track of localStream.getTracks()) {
    track.stop();
  }
  pc.close();
  remoteVideo.srcObject = null;
}
```

Muting should usually use `track.enabled = false`, not `track.stop()`. Stopping releases the device and requires reacquisition to resume.

## Renegotiation

Adding tracks, removing tracks, changing screen share, or creating data channels can trigger renegotiation. The hard part is glare: both peers create offers at the same time. Use the "perfect negotiation" pattern with polite and impolite peers, rollback, and stable signaling state checks. Without it, calls fail intermittently under real user behavior.

Keep signaling messages idempotent where possible. Users double-click buttons, tabs reconnect, and networks duplicate or delay messages.

## Data channels

`RTCDataChannel` provides peer-to-peer data over SCTP. It can be reliable or partially reliable depending on options. Use it for low-latency collaboration signals, game state, cursor positions, and file chunks, but respect backpressure through `bufferedAmount`.

```js
function sendWhenReady(channel, data) {
  if (channel.bufferedAmount > 1_000_000) {
    throw new Error("Data channel backpressure");
  }
  channel.send(data);
}
```

For large transfers, chunk data and wait for `bufferedamountlow` before sending more.

## Browser and codec constraints

The browser chooses codecs from what both peers advertise in SDP and what the device can encode or decode efficiently. Do not assume every client can send the same resolution, frame rate, or codec profile. Mobile devices may downscale, thermal throttle, or switch cameras with different capabilities. If quality matters, inspect sender parameters and stats instead of relying only on requested constraints.

Use `getUserMedia` constraints as preferences, then handle the stream you actually receive. A failed exact constraint should not block the whole call when a lower resolution would work.

## Diagnostics

`pc.getStats()` is the main diagnostic API. It exposes candidate pair state, bitrate, packet loss, jitter, frames encoded/decoded, round-trip time, and codec details. Build a debug panel for active calls. Browser logs are not enough when a user reports "video froze."

Useful events include `iceconnectionstatechange`, `connectionstatechange`, `signalingstatechange`, `negotiationneeded`, and `track.onended`. Log transitions with call ids.

```js
async function summarizeConnection(pc) {
  const stats = await pc.getStats();
  for (const report of stats.values()) {
    if (report.type === "candidate-pair" && report.state === "succeeded") {
      console.log("rtt", report.currentRoundTripTime, "bytesSent", report.bytesSent);
    }
    if (report.type === "inbound-rtp" && report.kind === "video") {
      console.log("framesDecoded", report.framesDecoded, "jitter", report.jitter);
    }
  }
}
```

Sample stats periodically during calls, but do not stream every raw report to analytics. Normalize the fields you need and capture snapshots around failures.

## Failure modes

Permissions can fail before WebRTC starts. Handle denied devices, missing devices, insecure origins, and device changes.

Autoplay policies can block remote audio until user interaction. Set media element properties intentionally and surface controls when playback fails.

Network changes can break candidate pairs. ICE restart can recover some sessions, but you need signaling support and state management.

Memory and device leaks are common. A closed modal that leaves camera tracks running is both a privacy issue and a resource leak.

Screen sharing has its own lifecycle. The user can stop sharing from browser chrome instead of your button, so listen for `track.onended` and update UI state from the track event, not only from local click handlers.

## Checklist

- Treat signaling as an application protocol with retries and ordering rules.
- Queue ICE candidates until remote descriptions are ready.
- Use TURN for production reliability.
- Stop tracks and close peer connections during teardown.
- Implement renegotiation defensively, especially glare handling.
- Respect `RTCDataChannel.bufferedAmount`.
- Build `getStats()` diagnostics for active sessions.
- Test permissions, device changes, restrictive networks, and tab lifecycle.
