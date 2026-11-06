# Language support

Choose **Harbor → Language**: Follow System, English or 简体中文. The preference is saved and applies on next launch. Supported Chinese variants use Simplified Chinese; unsupported system languages fall back to English.

Terminal contents, user names, paths and protocol identifiers remain unchanged. Unknown operating-system and third-party error messages can retain their original language.

Edit `app/Resources/zh-Hans.json`, then run from the repository root:

```sh
python3 scripts/generate-localization.py
python3 scripts/check-localization.py
bash app/tests/localization/run.sh
```

Keep the generated Swift catalog with its source JSON. Interpolation preserves user-supplied text without interpreting braces inside it as another template.
