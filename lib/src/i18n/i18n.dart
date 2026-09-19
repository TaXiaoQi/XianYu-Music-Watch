String tr(String key, [Map<String, Object?>? params]) {
  if (params == null || params.isEmpty) return key;
  return key.replaceAllMapped(
    RegExp(r'\{(\w+)\}'),
    (m) => (params[m[1]!] ?? '').toString(),
  );
}
