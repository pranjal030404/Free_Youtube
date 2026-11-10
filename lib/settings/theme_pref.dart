/// YouTube keeps its own "dark theme" switch in the `PREF` cookie: bit 0x400
/// of the hexadecimal `f6` field. Returns [pref] with that bit set or cleared,
/// leaving every other field as it was.
String prefWithDark(String? pref, {required bool dark}) {
  final parts = (pref ?? '').split('&').where((p) => p.isNotEmpty).toList();
  var f6 = 0;
  parts.removeWhere((p) {
    if (!p.startsWith('f6=')) return false;
    f6 = int.tryParse(p.substring(3), radix: 16) ?? 0;
    return true;
  });
  f6 = dark ? (f6 | 0x400) : (f6 & ~0x400);
  if (f6 != 0) parts.add('f6=${f6.toRadixString(16)}');
  return parts.join('&');
}
