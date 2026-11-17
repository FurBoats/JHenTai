/// A minimal 5-field cron expression evaluator:
/// `minute hour day-of-month month day-of-week`.
///
/// Each field supports `*`, a single value, comma lists, `a-b` ranges and
/// steps (`*/n`, `a-b/n`, `a/n`). The day-of-week field accepts 0-7, where
/// both 0 and 7 mean Sunday. When both day-of-month and day-of-week are
/// restricted, a date matches if either field matches (classic cron rule).
class CronExpression {
  final String source;

  final Set<int> _minutes;
  final Set<int> _hours;
  final Set<int> _daysOfMonth;
  final Set<int> _months;
  final Set<int> _daysOfWeek;
  final bool _domRestricted;
  final bool _dowRestricted;

  CronExpression._(
    this.source,
    this._minutes,
    this._hours,
    this._daysOfMonth,
    this._months,
    this._daysOfWeek,
    this._domRestricted,
    this._dowRestricted,
  );

  /// Parses [source]; returns null when the expression is invalid.
  static CronExpression? tryParse(String source) {
    try {
      return parse(source);
    } on FormatException {
      return null;
    }
  }

  static CronExpression parse(String source) {
    List<String> fields = source.trim().split(RegExp(r'\s+'));
    if (fields.length != 5) {
      throw FormatException('cron needs exactly 5 fields', source);
    }
    return CronExpression._(
      source,
      _parseField(fields[0], 0, 59, source),
      _parseField(fields[1], 0, 23, source),
      _parseField(fields[2], 1, 31, source),
      _parseField(fields[3], 1, 12, source),
      _parseField(fields[4], 0, 7, source).map((v) => v == 7 ? 0 : v).toSet(),
      fields[2] != '*',
      fields[4] != '*',
    );
  }

  static Set<int> _parseField(String field, int min, int max, String source) {
    Set<int> values = {};
    for (String part in field.split(',')) {
      if (part.isEmpty) {
        throw FormatException('empty cron field part', source);
      }
      String rangePart = part;
      int step = 1;
      int slash = part.indexOf('/');
      if (slash >= 0) {
        rangePart = part.substring(0, slash);
        step = int.tryParse(part.substring(slash + 1)) ?? 0;
        if (step <= 0) {
          throw FormatException('invalid cron step', source);
        }
      }
      int start;
      int end;
      if (rangePart == '*') {
        start = min;
        end = max;
      } else if (rangePart.contains('-')) {
        List<String> bounds = rangePart.split('-');
        if (bounds.length != 2) {
          throw FormatException('invalid cron range', source);
        }
        start = int.tryParse(bounds[0]) ?? -1;
        end = int.tryParse(bounds[1]) ?? -1;
      } else {
        start = int.tryParse(rangePart) ?? -1;
        // "a/n" means a..max with step n.
        end = slash >= 0 ? max : start;
      }
      if (start < min || start > max || end < min || end > max || start > end) {
        throw FormatException('cron value out of range', source);
      }
      for (int v = start; v <= end; v += step) {
        values.add(v);
      }
    }
    if (values.isEmpty) {
      throw FormatException('empty cron field', source);
    }
    return values;
  }

  bool matches(DateTime time) {
    if (!_minutes.contains(time.minute) ||
        !_hours.contains(time.hour) ||
        !_months.contains(time.month)) {
      return false;
    }
    bool domMatch = _daysOfMonth.contains(time.day);
    // DateTime.weekday: Monday = 1 .. Sunday = 7; cron: Sunday = 0.
    bool dowMatch = _daysOfWeek.contains(time.weekday % 7);
    if (_domRestricted && _dowRestricted) {
      return domMatch || dowMatch;
    }
    if (_domRestricted) {
      return domMatch;
    }
    if (_dowRestricted) {
      return dowMatch;
    }
    return true;
  }
}
