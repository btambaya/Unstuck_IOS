// The Talk screen's live caption line, as a pure reducer over the ONE callback
// VoiceRealtimeClient emits (`onCaption(role, text, done)`).
//
// It used to live inline in VoiceSessionModel.connect, where two ordering
// facts of the realtime protocol made the on-screen text wrong even when the
// audio was perfect:
//
//  • `conversation.item.input_audio_transcription.completed` (the ASR result
//    for what the USER said) is a SEPARATE async job from the reply. It
//    routinely lands a few hundred ms AFTER the model's first
//    `response.audio_transcript.delta`s — and the old sink cleared the caption
//    on every user event, so the first word or two of the reply was wiped off
//    the screen. The fix is not "clear less": it is to tell the two cases
//    apart. An EMPTY user caption is the barge-in "new turn, clear the
//    screen" signal (BargeInCommand.clearCaption) and always clears; a
//    NON-empty one is an ASR result, and it only clears a caption that is not
//    the live reply it belongs to.
//
//  • one user turn can produce SEVERAL reply segments — the model narrates,
//    calls a tool, and speaks again after the result, each segment ending with
//    `response.audio_transcript.done`. Their deltas were concatenated raw, so
//    the line read "Let me check.You have three today."
//
// Web (components/assistant/voice-mode.tsx) avoids both by clearing the
// caption on every `done` and never clearing it for a user event. iOS keeps
// its reply on screen while the audio plays out, so it separates segments
// instead of dropping the earlier one — that is the one deliberate difference.
//
// Pure + Sendable, so the whole thing is driven in tests from real server
// events (VoiceCaptionTests).

import Foundation

struct VoiceCaptionState: Equatable, Sendable {
    /// The assistant's reply as it streams, across every segment of this turn.
    private(set) var caption = ""
    /// The user's last transcribed turn — shown only while `caption` is empty.
    private(set) var userTranscript = ""
    /// A reply segment is streaming: its first delta arrived and its
    /// `response.audio_transcript.done` has not. While this is true a late ASR
    /// result belongs to the utterance that CAUSED the live reply, so it must
    /// not wipe it.
    private(set) var replyStreaming = false

    /// A new session / a hard interrupt / hold-to-talk press: nothing on screen.
    mutating func reset() { self = VoiceCaptionState() }

    /// One `onCaption(role:text:done:)` callback.
    mutating func apply(role: String, text: String, done: Bool) {
        if role == "user" {
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty {
                // Barge-in: this turn is over, whatever was on screen is stale.
                caption = ""
                replyStreaming = false
                return
            }
            userTranscript = t
            // The reply this utterance produced is already streaming — keep it.
            // Otherwise the caption is a finished reply from the PREVIOUS turn.
            if !replyStreaming { caption = "" }
            return
        }
        guard role == "assistant" else { return }
        if done {
            // Segment finished; its text stays on screen until the next turn.
            replyStreaming = false
            return
        }
        if text.isEmpty { return }
        if !replyStreaming {
            // A new segment of the SAME turn (narration → tool → answer):
            // "Let me check." + "You have three." must not run together.
            if let last = caption.last, !last.isWhitespace, let first = text.first, !first.isWhitespace {
                caption += " "
            }
            replyStreaming = true
        }
        caption += text
        userTranscript = ""
    }
}
