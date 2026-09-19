
use crate::player::output;

#[derive(Clone, Debug)]
pub enum PlaybackCommand {
    Play {
        path: String,
        device_id: i32,
        volume: f32,
        start_time_secs: f64,
        is_playing: bool,
        volume_balance_gain: f32,
        equalizer_settings_json: String,
        sound_effect_settings_json: String,
        bit_perfect: bool,
        dsd_native_passthrough: bool,
        shared_mode: bool,
    },
    Pause,
    Resume,
    Seek { time_secs: f64, is_playing: bool },
    Stop,
    SetVolume(f32),
    SetVolumeBalanceGain(f32),
    SetEqualizer(String),
    SetSoundEffect(String),
    SetBitPerfect(bool),
}

pub fn dispatch_playback_command(cmd: PlaybackCommand) -> Result<String, String> {
    match cmd {
        PlaybackCommand::Play {
            path,
            device_id,
            volume,
            start_time_secs,
            is_playing,
            volume_balance_gain,
            equalizer_settings_json,
            sound_effect_settings_json,
            bit_perfect,
            dsd_native_passthrough,
            shared_mode,
        } => {
            let request = output::ExclusivePlayRequest {
                path,
                device_id,
                volume,
                start_time_secs,
                is_playing,
                volume_balance_gain,
                equalizer_settings_json,
                sound_effect_settings_json,
                bit_perfect,
                dsd_native_passthrough,
                shared_mode,
            };
            output::start_exclusive_playback(request)
        }
        PlaybackCommand::Pause => {
            output::pause_exclusive();
            Ok(String::new())
        }
        PlaybackCommand::Resume => {
            output::resume_exclusive();
            Ok(String::new())
        }
        PlaybackCommand::Seek { time_secs, is_playing } => {
            output::seek_exclusive(time_secs, is_playing);
            Ok(String::new())
        }
        PlaybackCommand::Stop => {
            output::stop_exclusive_playback();
            Ok(String::new())
        }
        PlaybackCommand::SetVolume(volume) => {
            output::set_exclusive_volume(volume);
            Ok(String::new())
        }
        PlaybackCommand::SetVolumeBalanceGain(gain) => {
            output::set_exclusive_volume_balance_gain(gain);
            Ok(String::new())
        }
        PlaybackCommand::SetEqualizer(json) => {
            output::set_exclusive_equalizer(json)?;
            Ok(String::new())
        }
        PlaybackCommand::SetSoundEffect(json) => {
            output::set_exclusive_sound_effect(json)?;
            Ok(String::new())
        }
        PlaybackCommand::SetBitPerfect(enabled) => {
            output::set_exclusive_bit_perfect(enabled);
            Ok(String::new())
        }
    }
}