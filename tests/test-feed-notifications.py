from feed_the_flock.feed import resume_notification_message


def main() -> None:
    message = resume_notification_message(10, "Recovered Topics / Lifecycle Design")
    assert message == (
        "Resuming Recovered Topics / Lifecycle Design in 10…\nClick to cancel"
    )


if __name__ == "__main__":
    main()
