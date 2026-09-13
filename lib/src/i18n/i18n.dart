/// 腕上端单语言文案：直接返回键文本，支持 {name} 占位插值。
String tr(String key, [Map<String, Object?>? params]) {
  if (params == null || params.isEmpty) return key;
  return key.replaceAllMapped(
    RegExp(r'\{(\w+)\}'),
    (m) => (params[m[1]!] ?? '').toString(),
  );
}
