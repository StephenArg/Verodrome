import SwiftUI
import VerodromeKit

struct PlaybackSettingsView: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        Form {
            Section {
                Picker("On Wi-Fi", selection: $settings.streamingQualityWifi) {
                    ForEach(AudioTranscodeQuality.allCases) { quality in
                        Text(quality.displayName).tag(quality)
                    }
                }
                .pickerStyle(.navigationLink)
                .onChange(of: settings.streamingQualityWifi) { _, _ in settings.save() }

                Picker("On Cellular", selection: $settings.streamingQualityCellular) {
                    ForEach(AudioTranscodeQuality.allCases) { quality in
                        Text(quality.displayName).tag(quality)
                    }
                }
                .pickerStyle(.navigationLink)
                .onChange(of: settings.streamingQualityCellular) { _, _ in settings.save() }
            } header: {
                Text("Transcode Lossless")
            } footer: {
                Text("Live-convert FLAC, WAV, and other lossless files to MP3 while streaming. Already-compressed tracks stay original. Transcoded tracks are downloaded into the local cache so scrubbing does not re-hit the server. Requires server transcoding (for example ffmpeg on Navidrome).")
            }

            Section {
                Toggle("Gapless Playback", isOn: $settings.gaplessPlaybackEnabled)
                    .onChange(of: settings.gaplessPlaybackEnabled) { _, _ in settings.save() }

                Toggle("Crossfade", isOn: $settings.crossfadeEnabled)
                    .onChange(of: settings.crossfadeEnabled) { _, _ in settings.save() }

                if settings.crossfadeEnabled {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Duration")
                            Spacer()
                            Text("\(Int(settings.crossfadeDurationSeconds.rounded())) s")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $settings.crossfadeDurationSeconds, in: 1...12, step: 1) { editing in
                            // Persist on release rather than on every step of the drag.
                            if !editing { settings.save() }
                        }
                    }
                }
            } header: {
                Text("Transitions")
            } footer: {
                Text("Gapless keeps albums seamless by preloading the next track. Crossfade overlaps the two instead, and takes over from gapless when both are on. Neither applies while repeating one track.")
            }

            Section {
                Toggle("Replay Gain", isOn: $settings.replayGainEnabled)
                    .onChange(of: settings.replayGainEnabled) { _, _ in settings.save() }
            } header: {
                Text("Volume")
            } footer: {
                Text("Levels playback using the gain tags in your files. Tracks without tags play unchanged.")
            }

            Section {
                Picker("Count Play", selection: $settings.scrobbleTiming) {
                    ForEach(ScrobbleTiming.allCases) { timing in
                        Text(timing.displayName).tag(timing)
                    }
                }
                .pickerStyle(.navigationLink)
                .onChange(of: settings.scrobbleTiming) { _, _ in settings.save() }
            } header: {
                Text("Scrobbling")
            } footer: {
                Text("When a track has played far enough to report to your server as a play. Plays that happen offline are held and sent on the next connection. Never also stops Verodrome from counting plays on this device.")
            }
        }
        .verodromePlainList()
        .navigationTitle("Playback")
    }
}
