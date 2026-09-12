"""Connection strings: defaults merged, and passwords never printed.

Both jobs are pure text, so this runs anywhere. The redaction half is the
one that matters most: a `DATABASE_URL` carries its password in the
authority, and an error message is the most widely copied string a server
produces.
"""

from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_true,
)

from src.url import (
    DEFAULT_CONNECT_TIMEOUT,
    has_keyword,
    is_uri,
    read_only,
    redact,
    with_defaults,
)


# --- Redaction --------------------------------------------------------------


def test_a_password_in_the_authority_is_masked() raises:
    """The shape textshelf's own DATABASE_URL has.

    covers: O7
    """
    assert_equal(
        redact("postgres://app:s3cret@db.internal:5432/textshelf"),
        "postgres://app:***@db.internal:5432/textshelf",
    )
    # The user, host, port, database and query all survive: a redacted URL
    # has to stay diagnostic, or it is not printed and the password leaks
    # through whatever is printed instead.
    assert_equal(
        redact("postgresql://app:pw@h:5432/db?sslmode=require"),
        "postgresql://app:***@h:5432/db?sslmode=require",
    )


def test_a_password_keyword_is_masked_in_both_spellings() raises:
    """`libpq` takes a URI and a key/value conninfo; both can carry one.

    covers: O7
    """
    assert_equal(
        redact("host=db user=app password=s3cret dbname=x"),
        "host=db user=app password=*** dbname=x",
    )
    assert_equal(
        redact("postgres://db/x?user=app&password=s3cret&sslmode=require"),
        "postgres://db/x?user=app&password=***&sslmode=require",
    )


def test_a_url_with_no_password_is_unchanged() raises:
    """Redaction must not mangle what it has nothing to hide.

    covers: O7
    """
    for url in [
        "postgres://app@db:5432/x",
        "postgres:///postgres",
        "host=db dbname=x",
        "",
    ]:
        assert_equal(redact(url), url)


def test_a_word_ending_in_password_is_not_a_password_keyword() raises:
    """The boundary check: a keyword starts the string or follows a separator.

    covers: O7
    """
    var url = "host=db dbname=my_password_store"
    assert_equal(redact(url), url)


# --- Defaults ---------------------------------------------------------------


def test_defaults_are_added_to_a_uri_as_query_parameters() raises:
    """A URI gets its keywords as one query string.

    covers: O7
    """
    var out = with_defaults("postgres://db/app")
    assert_true(out.startswith("postgres://db/app?"))
    assert_true(has_keyword(out, "connect_timeout"))
    assert_true(has_keyword(out, "client_encoding"))
    assert_true(has_keyword(out, "application_name"))
    assert_true(has_keyword(out, "options"))
    # One `?`, the rest `&`: two would not parse.
    var question_marks = 0
    for b in out.as_bytes():
        if b == UInt8(ord("?")):
            question_marks += 1
    assert_equal(question_marks, 1)


def test_a_uri_that_already_has_a_query_keeps_it() raises:
    """The caller's own keywords survive the merge.

    covers: O7
    """
    var out = with_defaults("postgres://db/app?sslmode=require")
    assert_true(has_keyword(out, "sslmode"))
    assert_true(has_keyword(out, "connect_timeout"))
    assert_true("sslmode=require" in out)


def test_a_default_the_caller_set_is_not_overridden() raises:
    """Merged, not appended — the whole reason this function exists.

    libpq takes the LAST occurrence of a repeated keyword, so appending
    `connect_timeout=5` to a URL that sets 30 silently replaces it. That is
    a caller's explicit choice discarded by a default.

    covers: O7
    """
    var out = with_defaults("postgres://db/app?connect_timeout=30")
    assert_true("connect_timeout=30" in out)
    assert_false("connect_timeout=" + DEFAULT_CONNECT_TIMEOUT in out)
    # And only once: a second occurrence would be the appending bug with an
    # extra step.
    var count = 0
    var needle = String("connect_timeout=")
    var hay = out.as_bytes()
    var nb = needle.as_bytes()
    for i in range(len(hay) - len(nb) + 1):
        var matched = True
        for j in range(len(nb)):
            if hay[i + j] != nb[j]:
                matched = False
                break
        if matched:
            count += 1
    assert_equal(count, 1)


def test_a_key_value_conninfo_gets_key_value_defaults() raises:
    """The other spelling, which must not be given a query string.

    covers: O7
    """
    var out = with_defaults("host=db dbname=app")
    assert_false(is_uri(out))
    assert_false("?" in out)
    assert_true("connect_timeout=5" in out)
    # `options` carries spaces, so its value is quoted rather than encoded.
    assert_true("options='-c statement_timeout=" in out)


def test_the_statement_timeout_rides_the_options_keyword() raises:
    """A bound on one statement, applied at the connection.

    covers: O7
    """
    assert_true("statement_timeout" in with_defaults("postgres://db/app"))
    assert_true("statement_timeout" in with_defaults("host=db"))


def test_read_only_adds_a_transaction_default_to_the_same_options() raises:
    """`libpq` takes ONE options keyword, so this extends rather than repeats.

    covers: O7
    """
    var uri = read_only("postgres://db/app")
    assert_true("default_transaction_read_only" in uri)
    var count = 0
    for i in range(len(uri.as_bytes()) - 7):
        if String(unsafe_from_utf8=uri.as_bytes()[i : i + 8]) == "options=":
            count += 1
    assert_equal(count, 1)
    var kv = read_only("host=db dbname=app")
    assert_true("-c default_transaction_read_only=on'" in kv)


def test_read_only_refuses_a_url_that_owns_its_options() raises:
    """Half-applying the promise is worse than declining to apply it.

    A second `options` keyword would silently replace the caller's, and
    folding into theirs would need this package to parse a command line it
    does not own. Saying so is the honest third choice.

    covers: O7
    """
    var raised = False
    try:
        _ = read_only("postgres://db/app?options=-c%20work_mem%3D64MB")
    except e:
        raised = True
        assert_true("already sets" in String(e))
    assert_true(raised)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
