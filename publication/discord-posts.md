# Discord post drafts

## Omarchy community

Hey, I’m sharing Feed the Flock, an Omarchy plugin I’ve been working on for
organizing notes and feeding them into Herdr agents.

I built it because I tend to collect prompts and feedback faster than an agent
can work through them. Feed the Flock gives those thoughts somewhere to wait.
I can sort them into sections, choose what runs next, or send an urgent note
immediately.

I’ve been dogfooding it heavily. Much of the plugin’s own development was
planned and fed through Feed the Flock itself, and it has reached the point
where I’d like to see whether it is useful to anyone else.

It has a compact Omarchy panel for capture and feed control, plus a local
workspace for editing, drag and drop, attachments, submitted history, and
keyboard navigation.

Repository: https://github.com/pjgeutjens/omarchy-feed-the-flock

```sh
omarchy plugin add https://github.com/pjgeutjens/omarchy-feed-the-flock.git --enable
```

Feedback is welcome, especially from people already using Herdr for longer
agent sessions.

Suggested attachment: `preview.png`

## Herdr users

Hey, I’ve been building Feed the Flock, a note organizer and note-feeding
system for Herdr.

The problem it solves is simple: I often have the next prompt ready while an
agent is still working. Sending it immediately can interrupt the current turn,
and keeping it in my head doesn’t work either. Feed the Flock stores those
notes in an ordered queue and sends them when the selected Herdr agent is
ready.

Sections can be queued independently. Notes can run one by one or as a batch,
and Feed Now is there when something shouldn’t wait. The queue remains active
even when I browse or edit another bucket.

I’ve been using it to develop the plugin itself. It now feels ready to share
and see how it behaves in other people’s workflows.

Repository: https://github.com/pjgeutjens/omarchy-feed-the-flock

Suggested attachment: the final 20–30 second demo, with `preview.png` as a
fallback.

## Posting notes

- Post the Omarchy version with the marketplace listing or panel screenshot.
- Post the Herdr version with the short recording once it has been recaptured.
- Do not attach both screenshots and the recording to the same post.
- Keep technical requirements in the repository instead of extending the post.
