# Testing this build on a real receiver

This branch is dump1090-fa 11.1 with security fixes and speed improvements.
On every recording and test input checked so far, it decodes exactly the same
messages, byte for byte, as the official 11.1 build. It uses roughly half the
CPU on desktop and ARM64 machines. What hasn't been checked yet is how it
behaves on real Raspberry Pis with real dongles and antennas. That is what
this guide is for.

There are two steps. Do the first one before the second.

## What is different from 11.1

You should not notice any of these on a normal feeder:

- **Mode A/C replies** (only when Mode A/C decoding is on, for example when
  mlat asks for it). 11.1 sometimes showed the previous reply's altitude on a
  reply that had no altitude. This build leaves the altitude blank instead.
- **Receiver location from the Beast input.** 11.1 let anything connected to
  the Beast input ports (30004/30104) set the receiver location with a
  Radarcape position message. This build ignores those messages unless you add
  `--net-accept-position`. This only matters if you feed a Radarcape into
  dump1090-fa and rely on it for the location. In that case, set `RECEIVER_LAT`
  and `RECEIVER_LON` in `/etc/default/dump1090-fa`, or add
  `--net-accept-position` to `EXTRA_OPTIONS` there.
- **Limits under a flood of fake aircraft.** At most 10,000 aircraft are
  tracked at once (real traffic is far below this), and the address filter can
  no longer fill up. The "ICAO hash table full" log message is gone.
- **Web map.** Crafted links can no longer hang the page with a huge number of
  range rings.

## Step 1: a quick, exact check (about 30 minutes; the feeder is off for about 2)

This records two minutes of raw radio signal from your dongle. It then decodes
that same recording with both the official code and this build, checks that
the results are identical, and times both on your Pi.

```bash
git clone -b claude/peaceful-archimedes-so5ki2 https://github.com/izy/dump1090-fa ~/dump1090-test
```

```bash
cd ~/dump1090-test && tools/pi-test.sh --install-deps
```

- **Feeder downtime:** if dump1090-fa is running, the script stops it for the
  recording and starts it again straight afterwards. Building and comparing
  then takes 10–30 minutes on a Pi 4, and longer on older models, while your
  feeder carries on as normal.
- **Disk space:** the recording needs about 600 MB. The script tells you where
  it is, so you can delete it afterwards.
- **Options:** `--seconds 60` makes a shorter recording. `--pause-feeder`
  keeps the feeder off for the whole run, which gives cleaner timings.

When it finishes, it prints a short report and saves it as
`~/dump1090-pi-test/pi-test-result.md`. Please send that file back.

- **PASS** means every output was identical, or differed only by the Mode A/C
  altitude fix above.
- **FAIL** means something differed. The report and `~/dump1090-pi-test/compare`
  hold the details.

## Step 2: run it live for a week

Only do this once step 1 has passed.

### Get the package

Find which package your Pi needs:

```bash
dpkg --print-architecture; . /etc/os-release; echo $VERSION_CODENAME
```

This prints, for example, `arm64` and `bookworm`.

- **`arm64`, `armhf` or `amd64`, with `bookworm` or `trixie`:** download the
  matching `dump1090-fa-<release>-<architecture>` package. It is under
  "Artifacts" on the latest successful run of
  [Build test packages](https://github.com/izy/dump1090-fa/actions/workflows/packages.yaml)
  (you need to be signed in to GitHub). Unzip it and copy the `.deb` file to
  the Pi.
- **Pi Zero or Pi 1:** these have an ARMv6 CPU, which the downloadable
  `armhf` packages can't run on. Build the package on the Pi itself instead.
  It is slow, but it works:

  ```bash
  cd ~/dump1090-test && tools/build-test-package.sh --install-deps
  ```

  The package ends up in `~/dump1090-test/test-packages/`.

### Install it

First, write down the version you have now, so you can go back to it:

```bash
dpkg-query -W dump1090-fa | tee ~/dump1090-fa-official-version.txt
```

Then install the test package (use the real file name) and restart the
service:

```bash
sudo apt install ./dump1090-fa_11.1+test*.deb
```

```bash
sudo systemctl restart dump1090-fa
```

The version now ends in `+test<number>`. Check that it is running:

```bash
systemctl status dump1090-fa
```

Your settings in `/etc/default/dump1090-fa` are kept.

### What to watch

Compare the following against your usual numbers. Expect some day-to-day
variation from traffic and weather.

- **Messages per second, aircraft seen, and maximum range:** on the SkyAware
  map, your FlightAware stats page, or graphs1090 if you use it.
- **CPU use:** this should go down. The following shows the total CPU time
  used against the time running; note it before you install and again a day
  after:

  ```bash
  ps -o etime,time,rss -C dump1090-fa
  ```

- **Memory:** the `rss` column above should stay roughly steady over days. It
  should not keep climbing.
- **Restarts and errors:**

  ```bash
  systemctl show dump1090-fa -p NRestarts
  ```

  ```bash
  journalctl -u dump1090-fa --since "1 day ago" | tail -50
  ```

- **PiAware and mlat** (if you use them): `piaware-status` should still show
  dump1090 connected and mlat working.

### Going back to the official version

Find the official version:

```bash
apt-cache policy dump1090-fa
```

Install it (use the version that the command above, or
`~/dump1090-fa-official-version.txt`, shows), then restart the service:

```bash
sudo apt install --allow-downgrades dump1090-fa=VERSION
```

```bash
sudo systemctl restart dump1090-fa
```

If you installed dump1090-fa from a downloaded file rather than the
FlightAware package repository, reinstall that file instead.

### What to send back after a week

- The step 1 report (`pi-test-result.md`)
- Pi model, OS release, and the test package version
- Any crashes, restarts or odd log messages
- CPU before and after (the `ps` output above)
- Whether messages, aircraft and range looked the same as usual
