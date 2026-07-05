# C60 Audio

The C60 exposes one ALSA sound card named `keplerc60`.

Observed on hardware:

```text
card 0: keplerc60 [kepler-c60]
  hw:keplerc60,0  Speaker Playback tas571x-hifi-0
  hw:keplerc60,1  Mic Array Capture multicodec-1
```

The playback path is the internal conference speaker amplifier. The capture path is the internal microphone array.

## Hardware Topology

- SoC: NXP i.MX 8M Mini.
- Audio bus: SAI1.
- Playback codec/amplifier: TAS5751M-compatible `tas571x` device.
- Capture codecs: three TLV320ADC3101 ADCs.
- ALSA card id: `keplerc60`.
- ALSA playback PCM: `hw:keplerc60,0`.
- ALSA capture PCM: `hw:keplerc60,1`.

The kernel machine driver is `poly,c60-audio`. It exposes two DAI links on one card:

- `Speaker Playback`: SAI1 to TAS5751M, playback-only.
- `Mic Array Capture`: SAI1 from three TLV320ADC3101 devices, capture-only.

SAI1 provides the shared bit clock and frame clock. The microphone ADCs run as clock consumers and are configured by the machine driver at card bring-up. Users should not need an `amixer` setup step before recording.

## Installed Tools

The C60 rootfs includes `alsa-utils`, which provides:

- `speaker-test`
- `aplay`
- `arecord`
- `amixer`
- `alsactl`
- `alsaucm`

It also includes `ffmpeg` for decoding compressed formats such as M4A/AAC, MP3, and FLAC into PCM for ALSA playback.

## Device Discovery

```sh
cat /proc/asound/cards
cat /proc/asound/pcm
ls -l /dev/snd
aplay -l
arecord -l
alsaucm listcards
alsaucm -c keplerc60 list _verbs
```

Expected ALSA nodes:

```text
/dev/snd/controlC0
/dev/snd/pcmC0D0p
/dev/snd/pcmC0D1c
/dev/snd/timer
```

## Speaker Playback

Set the speaker volume and unmute the amplifier:

```sh
amixer -c keplerc60 set 'Spk Master' 100%
amixer -c keplerc60 set 'Spk Speaker' 100% unmute
```

Run a short stereo speaker test:

```sh
speaker-test -D hw:keplerc60,0 -c 2 -r 48000 -F S16_LE -t sine -f 1000 -l 1
```

Play a WAV file directly to the C60 speaker:

```sh
aplay -D hw:keplerc60,0 file.wav
```

For compressed files, decode to 48 kHz stereo S16_LE before handing audio to ALSA. The C60 playback path accepts this format reliably; 44.1 kHz input files such as many M4A files should be resampled.

```sh
ffmpeg -hide_banner -i song.m4a -vn -ac 2 -ar 48000 -sample_fmt s16 -f wav - | aplay -D hw:keplerc60,0 -
ffmpeg -hide_banner -i song.mp3 -vn -ac 2 -ar 48000 -sample_fmt s16 -f wav - | aplay -D hw:keplerc60,0 -
ffmpeg -hide_banner -i song.flac -vn -ac 2 -ar 48000 -sample_fmt s16 -f wav - | aplay -D hw:keplerc60,0 -
```

To convert once and play with `aplay` later:

```sh
ffmpeg -hide_banner -y -i song.m4a -vn -ac 2 -ar 48000 -sample_fmt s16 /tmp/song.wav
aplay -D hw:keplerc60,0 /tmp/song.wav
```

## Microphone Capture

Record from the microphone array:

```sh
arecord -D hw:keplerc60,1 -f S16_LE -r 48000 -c 6 mic-array.wav
```

For raw inspection:

```sh
arecord -D hw:keplerc60,1 -f S16_LE -r 48000 -c 6 --duration=5 /tmp/c60-mics.wav
```

The hardware has three stereo ADCs. The machine driver programs the fixed input routing, PGA gain, and unmute state at boot. The UCM profile intentionally does not expose a single capture master volume because the three ADCs have independent gains.

## Mixer Controls

List controls:

```sh
amixer -c keplerc60 scontrols
amixer -c keplerc60 contents
```

Useful speaker controls:

```text
Spk Speaker
Spk Master
```

## Troubleshooting

If no card appears:

```sh
dmesg | grep -Ei 'c60|asoc|alsa|snd|sai|tas57|tlv320|sdma|audio'
cat /proc/asound/cards
```

Expected kernel signs include:

```text
ALSA device list:
  #0: kepler-c60
```

If playback says the device is busy, stop the application holding the PCM device and retry. The hardware playback device exposes one playback substream.

If an app only accepts numeric ALSA devices, use `hw:0,0` for speaker playback and `hw:0,1` for microphone capture. Prefer `hw:keplerc60,0` and `hw:keplerc60,1` in scripts because the card name is stable.
