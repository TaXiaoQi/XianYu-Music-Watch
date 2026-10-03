use crate::music::lyric_formats::{
    decrypt_qrc_hex, parse_eslrc, parse_lys, parse_qrc, parse_yrc, LyricLine as SourceLine,
};
use regex::Regex;
use serde::Serialize;
use std::cmp::Ordering;
use std::collections::{BTreeMap, HashSet};
use std::sync::OnceLock;

mod lx_convert;
mod parse;
mod semantic;
mod tracks;
mod types;

pub(crate) use lx_convert::*;
pub(crate) use parse::*;
pub(crate) use semantic::*;
pub(crate) use tracks::*;
pub(crate) use types::*;

#[cfg(test)]
mod tests {
    use super::{
        build_structured_lyrics_payload, parse_raw_lyrics, score_romanized_latin_text,
        ParsedLineSourceFormat,
    };

    #[test]
    fn parses_inline_timestamp_lrc_into_word_timed_lines() {
        let parsed = parse_raw_lyrics(
            "[00:00.000]如[00:00.375]果[00:00.750]当[00:01.125]时[00:01.500] [00:01.875]-[00:02.250] [00:02.625]许[00:03.000]嵩[00:03.375]",
        );

        assert_eq!(parsed.len(), 1);
        assert_eq!(parsed[0].text, "如果当时 - 许嵩");
    }

    #[test]
    fn hard_role_rules_keep_single_line_as_main() {
        let payload = build_structured_lyrics_payload("[00:01.000]Hello darling".to_string());

        assert_eq!(payload.display_lines.len(), 1);
        assert_eq!(payload.display_lines[0].text, "Hello darling");
        assert_eq!(payload.display_lines[0].translation, "");
        assert_eq!(payload.display_lines[0].romaji, "");
    }

    #[test]
    fn hard_role_rules_treat_han_only_line_as_translation_for_two_lines() {
        let payload = build_structured_lyrics_payload(
            ["[00:01.000]你知道你爱我", "[00:01.000]You know you love me"].join("\n"),
        );

        assert_eq!(payload.display_lines.len(), 1);
        assert_eq!(payload.display_lines[0].text, "You know you love me");
        assert_eq!(payload.display_lines[0].translation, "你知道你爱我");
        assert_eq!(payload.display_lines[0].romaji, "");
    }

    #[test]
    fn hard_role_rules_treat_mixed_han_latin_as_translation_for_two_lines() {
        let payload = build_structured_lyrics_payload(
            ["[00:01.000]你好 darling", "[00:01.000]hello darling"].join("\n"),
        );

        assert_eq!(payload.display_lines.len(), 1);
        assert_eq!(payload.display_lines[0].text, "hello darling");
        assert_eq!(payload.display_lines[0].translation, "你好 darling");
        assert_eq!(payload.display_lines[0].romaji, "");
    }

    #[test]
    fn hard_role_rules_fall_back_to_first_main_second_translation_for_two_lines() {
        let payload = build_structured_lyrics_payload(
            [
                "[00:01.000]first latin line",
                "[00:01.000]second latin line",
            ]
            .join("\n"),
        );

        assert_eq!(payload.display_lines.len(), 1);
        assert_eq!(payload.display_lines[0].text, "first latin line");
        assert_eq!(payload.display_lines[0].translation, "second latin line");
        assert_eq!(payload.display_lines[0].romaji, "");
    }

    #[test]
    fn hard_role_rules_use_fixed_roman_main_translation_order_for_three_lines() {
        let payload = build_structured_lyrics_payload(
            [
                "[00:01.000]wa su re ta ku na i ko to",
                "[00:01.000]忘れたくないこと",
                "[00:01.000]我不愿遗忘",
            ]
            .join("\n"),
        );

        assert_eq!(payload.display_lines.len(), 1);
        assert_eq!(payload.display_lines[0].text, "忘れたくないこと");
        assert_eq!(payload.display_lines[0].translation, "我不愿遗忘");
        assert_eq!(payload.display_lines[0].romaji, "wa su re ta ku na i ko to");
    }

    #[test]
    fn keeps_japanese_main_when_romaji_comes_first() {
        let payload = build_structured_lyrics_payload(
            [
                "[01:01.072]<01:01.072>wa <01:01.336>su <01:01.633>re <01:01.863>ta <01:02.103>ku <01:02.352>na <01:02.577>i <01:02.823>ko <01:03.159>to <01:03.553>",
                "[01:01.072]<01:01.072>忘<01:01.633>れ<01:01.863>た<01:02.103>く<01:02.352>な<01:02.577>い<01:02.823>こ<01:03.159>と<01:03.553>",
                "[01:01.072]<01:01.072>我不愿遗忘<01:03.790>",
            ]
            .join("\n"),
        );

        assert_eq!(payload.display_lines.len(), 1);
        assert_eq!(payload.display_lines[0].text, "忘れたくないこと");
        assert_eq!(payload.display_lines[0].translation, "我不愿遗忘");
        assert_eq!(payload.display_lines[0].romaji, "wa su re ta ku na i ko to");
    }

    #[test]
    fn prefers_lx_converted_enhanced_lrc_as_word_timed_source() {
        let parsed = parse_raw_lyrics(
            [
                "[00:10.000]<00:10.000>其<00:10.300>实<00:10.600>",
                "[00:12.000]<00:12.000>天<00:12.400>外<00:12.800>",
            ]
            .join("\n")
            .as_str(),
        );

        assert_eq!(parsed.len(), 2);
        assert_eq!(parsed[0].source_format, ParsedLineSourceFormat::EnhancedLrc);
        assert_eq!(parsed[0].text, "其实");
        assert_eq!(
            parsed[0]
                .words
                .as_ref()
                .map(|words| words
                    .iter()
                    .map(|word| word.text.as_str())
                    .collect::<Vec<_>>())
                .unwrap_or_default(),
            vec!["其", "实"]
        );
    }

    #[test]
    fn structured_payload_keeps_words_for_lx_converted_enhanced_lrc() {
        let payload = build_structured_lyrics_payload(
            [
                "[00:10.000]<00:10.000>其<00:10.300>实<00:10.600>",
                "[00:12.000]<00:12.000>天<00:12.400>外<00:12.800>",
            ]
            .join("\n"),
        );

        assert_eq!(payload.display_lines.len(), 2);
        assert_eq!(payload.display_lines[0].text, "其实");
        assert_eq!(
            payload.display_lines[0]
                .words
                .as_ref()
                .map(|words| words
                    .iter()
                    .map(|word| word.text.as_str())
                    .collect::<Vec<_>>())
                .unwrap_or_default(),
            vec!["其", "实"]
        );
    }

    #[test]
    fn converts_lx_relative_word_tags_to_absolute_enhanced_lrc() {
        let converted = super::convert_lx_relative_to_enhanced(
            "[00:10.000]<0,300>其<300,300>实\n[00:12.000]<0,400>天<400,400>外",
        )
        .expect("should convert");

        assert_eq!(
            converted,
            [
                "[00:10.000]<00:10.000>其<00:10.300>实<00:10.600>",
                "[00:12.000]<00:12.000>天<00:12.400>外<00:12.800>",
            ]
            .join("\n")
        );
    }

    #[test]
    fn converts_kuwo_style_word_tags_with_negative_encoding() {
        let converted = super::convert_lx_relative_to_enhanced("你<-9343,6229>好<-3105,6229>")
            .expect("should convert");

        assert!(converted.starts_with("[00:"));
        assert!(super::abs_word_tag_re().is_match(&converted));
        assert!(converted.contains("你"));
        assert!(converted.contains("好"));
    }

    #[test]
    fn structured_payload_keeps_words_for_lx_relative_format() {
        let payload = build_structured_lyrics_payload(
            [
                "[00:10.000]<0,300>其<300,300>实",
                "[00:12.000]<0,400>天<400,400>外",
            ]
            .join("\n"),
        );

        assert_eq!(payload.display_lines.len(), 2);
        assert_eq!(payload.display_lines[0].text, "其实");
        let words = payload.display_lines[0]
            .words
            .as_ref()
            .expect("words must survive parsing");
        assert_eq!(words[0].text, "其");
        assert!((words[0].start - 10.0).abs() < 1e-6);
        assert!((words[0].end - 10.3).abs() < 1e-6);
        assert_eq!(words[1].text, "实");
        assert!((words[1].start - 10.3).abs() < 1e-6);
        assert!((words[1].end - 10.6).abs() < 1e-6);
    }

    #[test]
    fn plain_lrc_passes_through_lx_converter_untouched() {
        assert_eq!(
            super::convert_lx_relative_to_enhanced("[00:01.000]普通歌词行"),
            None
        );
    }

    #[test]
    fn parses_yrc_fixture_into_word_timed_lines() {
        let parsed = parse_raw_lyrics(include_str!("../fixtures/lyrics/if_back_then.yrc"));

        assert_eq!(parsed.len(), 2);
        assert_eq!(parsed[0].source_format, ParsedLineSourceFormat::Yrc);
        assert_eq!(parsed[0].text, "如果当时 - 许嵩");
        assert_eq!(
            parsed[0]
                .words
                .as_ref()
                .map(|words| words
                    .iter()
                    .map(|word| word.text.as_str())
                    .collect::<Vec<_>>())
                .unwrap_or_default(),
            vec!["如", "果", "当", "时", " ", "-", " ", "许", "嵩"]
        );
        assert_eq!(parsed[1].text, "词：许嵩");
    }

    #[test]
    fn parses_qrc_fixture_into_word_timed_lines() {
        let parsed = parse_raw_lyrics(include_str!("../fixtures/lyrics/baby.qrc"));

        assert_eq!(parsed.len(), 2);
        assert_eq!(parsed[0].source_format, ParsedLineSourceFormat::Qrc);
        assert_eq!(parsed[0].text, "You know you love me I know you care");
        assert_eq!(
            parsed[0]
                .words
                .as_ref()
                .map(|words| words
                    .iter()
                    .map(|word| word.text.as_str())
                    .collect::<Vec<_>>())
                .unwrap_or_default(),
            vec!["You ", "know ", "you ", "love ", "me", " I ", "know ", "you ", "care",]
        );
        assert_eq!(parsed[1].text, "你知道你爱我 我知道你在意");
    }

    #[test]
    fn parses_qq_real_qrc_fixture() {
        // Baka QQ 插件解密产物（天外来物真实 QRC XML）：解析兼容性回归
        let parsed = parse_raw_lyrics(include_str!("../fixtures/lyrics/qq_real.qrc"));

        assert!(
            !parsed.is_empty(),
            "QQ 真实 QRC XML 应解析出歌词行，实际 0 行"
        );
        assert_eq!(parsed[0].source_format, ParsedLineSourceFormat::Qrc);
        assert!(
            parsed.iter().all(|line| !line.text.trim().is_empty()),
            "解析行不应有空文本"
        );
    }

    #[test]
    fn parses_qq_qrc_mixed_with_translation_lrc() {
        // 宿主取词链把解密 QRC XML 与插件译文 LRC 拼成一份 lyricsRaw：应走
        // Qrc 逐字解析，且译文按时间戳关联出 translated_text 而不是丢弃
        let raw = format!(
            "{}\n[00:21.50]这是译文第一行\n[00:45.00]这是译文第二行",
            include_str!("../fixtures/lyrics/qq_real.qrc")
        );
        let parsed = parse_raw_lyrics(&raw);

        assert!(
            !parsed.is_empty(),
            "QRC XML + 译文 LRC 混合文本应解析出歌词行，实际 0 行"
        );
        assert_eq!(
            parsed[0].source_format,
            ParsedLineSourceFormat::Qrc,
            "混合文本应走 Qrc 逐字分支，实际走了 {:?}",
            parsed[0].source_format
        );
        assert!(
            parsed[0].words.as_ref().map(|w| !w.is_empty()).unwrap_or(false),
            "Qrc 行应保留逐字 words"
        );
        let with_translation = parsed
            .iter()
            .find(|line| line.translated_text.as_deref().map(|t| !t.trim().is_empty()).unwrap_or(false));
        assert!(
            with_translation.is_some(),
            "译文 LRC 应关联出 translated_text，实际全部为空；行数={}，前3行文本={:?}",
            parsed.len(),
            parsed.iter().take(3).map(|l| l.text.as_str()).collect::<Vec<_>>()
        );
    }

    #[test]
    fn parses_lys_fixture_into_word_timed_lines() {
        let parsed = parse_raw_lyrics(include_str!("../fixtures/lyrics/from_that_day.lys"));

        assert_eq!(parsed.len(), 2);
        assert_eq!(parsed[0].source_format, ParsedLineSourceFormat::Lys);
        assert_eq!(parsed[0].text, "その日から何もかも");
        assert_eq!(
            parsed[0]
                .words
                .as_ref()
                .map(|words| words
                    .iter()
                    .map(|word| word.text.as_str())
                    .collect::<Vec<_>>())
                .unwrap_or_default(),
            vec!["そ", "の日から", "何もかも"]
        );
        assert_eq!(parsed[1].text, "忘れたくないこと");
    }

    #[test]
    fn romaji_scoring_prefers_vowel_ending_token_sequences() {
        let spaced_romaji = "ha ji me te no ru bu ru wa";
        let compressed_latin = "hajimetenoruburuwa";

        assert!(
            score_romanized_latin_text(spaced_romaji)
                > score_romanized_latin_text(compressed_latin)
        );
    }

    #[test]
    fn romaji_scoring_supports_n_and_ng_endings() {
        let n_ending_romaji = "shi n ji te i ru n da";
        let ng_ending_pinyin = "xiang xin ni reng zai zhe li";

        assert!(score_romanized_latin_text(n_ending_romaji) > 0.45);
        assert!(score_romanized_latin_text(ng_ending_pinyin) > 0.35);
    }

    #[test]
    fn romaji_scoring_keeps_english_phrases_below_romaji_lines() {
        let english_phrase = "Can you give me one last kiss";
        let romaji_line = "mo u to kku ni de a't te ta ka ra";

        assert!(score_romanized_latin_text(english_phrase) < 0.35);
        assert!(
            score_romanized_latin_text(romaji_line) > score_romanized_latin_text(english_phrase)
        );
    }

    #[test]
    fn hard_role_rules_deduplicate_identical_main_and_translation() {
        let payload = build_structured_lyrics_payload(
            ["[00:01.000]相同歌词", "[00:01.000]相同歌词"].join("\n"),
        );

        assert_eq!(payload.display_lines.len(), 1);
        assert_eq!(payload.display_lines[0].text, "相同歌词");
        assert_eq!(payload.display_lines[0].translation, "");
        assert_eq!(payload.display_lines[0].romaji, "");
    }

    #[test]
    fn hard_role_rules_keep_different_main_and_translation() {
        let payload =
            build_structured_lyrics_payload(["[00:01.000]Hello", "[00:01.000]你好"].join("\n"));

        assert_eq!(payload.display_lines.len(), 1);
        assert_eq!(payload.display_lines[0].text, "Hello");
        assert_eq!(payload.display_lines[0].translation, "你好");
    }
}
