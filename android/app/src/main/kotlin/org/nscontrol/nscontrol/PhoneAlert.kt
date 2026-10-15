package org.nscontrol.nscontrol

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.os.Handler
import android.os.Looper
import android.os.VibrationEffect
import android.os.Vibrator
import kotlin.math.PI
import kotlin.math.sin

class PhoneAlert(context: Context) {
    private val vibrator = context.getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
    private val handler = Handler(Looper.getMainLooper())
    private var track: AudioTrack? = null
    fun start(volume: Double, vibrate: Boolean, test: Boolean = false) {
        require(volume.isFinite() && volume in 0.0..1.0) { "volume must be between 0 and 1" }
        stop()
        val samples = ShortArray(44100) { index ->
            val active = index % 22050 < 13230
            val taper = minOf(1.0, (index % 22050).toDouble()/220,
                (13230 - index % 22050).toDouble()/220).coerceAtLeast(0.0)
            if (active) (sin(2 * PI * 880 * index/44100) * 24000 * taper).toInt().toShort() else 0
        }
        val audio = AudioTrack.Builder()
            .setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_ALARM)
                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION).build())
            .setAudioFormat(AudioFormat.Builder().setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                .setSampleRate(44100).setChannelMask(AudioFormat.CHANNEL_OUT_MONO).build())
            .setBufferSizeInBytes(samples.size * 2).setTransferMode(AudioTrack.MODE_STATIC).build()
        track = audio
        check(audio.state == AudioTrack.STATE_INITIALIZED) { "AudioTrack initialization failed" }
        check(audio.write(samples, 0, samples.size) == samples.size) { "Incomplete audio buffer" }
        check(audio.setLoopPoints(0, samples.size, -1) == AudioTrack.SUCCESS)
        check(audio.setVolume(volume.toFloat()) == AudioTrack.SUCCESS)
        audio.play()
        if (vibrate && vibrator.hasVibrator()) {
            vibrator.vibrate(VibrationEffect.createWaveform(longArrayOf(0, 350, 350), 0))
        }
        if (test) handler.postDelayed({ stop() }, 1500)
    }
    fun stop() {
        handler.removeCallbacksAndMessages(null)
        track?.run { runCatching { stop() }; release() }; track = null
        vibrator.cancel()
    }
}
