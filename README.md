# credfeto-gickup

## Watchtower schedule

The `watchtower` service checks for updated images on a cron schedule rather than a fixed poll interval.

- Default schedule: `0 24 * * * *`, which runs hourly at minute 24.
- The schedule uses Watchtower's 6-field cron format, with seconds first: `seconds minutes hours day-of-month month day-of-week`.
- Old images are removed after an update, because `WATCHTOWER_CLEANUP` is set to `true`.

### Overriding the schedule

Copy `example.env` to `.env` in the same directory as `docker-compose.yml`, then change `WATCHTOWER_SCHEDULE`:

```sh
cp example.env .env
```

Docker Compose reads `.env` automatically. The `.env` file is git-ignored, so local settings are never committed.
