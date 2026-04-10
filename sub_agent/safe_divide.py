"""Module providing a safe division function with comprehensive error handling."""

import logging
import math
from typing import Union

logger = logging.getLogger(__name__)

Numeric = Union[int, float]


def safe_divide(a: Numeric, b: Numeric) -> float:
    """Safely divide two numbers with comprehensive error handling.

    Args:
        a: The numerator. Must be int or float (not bool).
        b: The denominator. Must be int or float (not bool).

    Returns:
        The result of a / b as a float.

    Raises:
        TypeError: If either argument is not a numeric type or is a bool.
        ValueError: If either argument is inf or NaN, or if a very large
            int causes an OverflowError during division.
        ZeroDivisionError: If b is zero.
    """
    if isinstance(a, bool) or isinstance(b, bool):
        logger.error("Boolean inputs are not allowed: a=%r, b=%r", a, b)
        raise TypeError("Boolean values are not accepted; pass int or float instead.")

    if not isinstance(a, (int, float)):
        logger.error("Invalid type for numerator: %s (%r)", type(a).__name__, a)
        raise TypeError(f"Numerator must be int or float, got {type(a).__name__}.")

    if not isinstance(b, (int, float)):
        logger.error("Invalid type for denominator: %s (%r)", type(b).__name__, b)
        raise TypeError(f"Denominator must be int or float, got {type(b).__name__}.")

    if isinstance(a, float) and math.isnan(a) or isinstance(b, float) and math.isnan(b):
        logger.error("NaN detected in inputs: a=%r, b=%r", a, b)
        raise ValueError("NaN is not a valid input for division.")

    if isinstance(a, float) and math.isinf(a) or isinstance(b, float) and math.isinf(b):
        logger.error("Infinity detected in inputs: a=%r, b=%r", a, b)
        raise ValueError("Infinite values are not valid inputs for division.")

    if b == 0:
        logger.error("Division by zero attempted: %r / %r", a, b)
        raise ZeroDivisionError("Cannot divide by zero.")

    try:
        result = a / b
    except OverflowError:
        logger.error("Overflow during division: %r / %r", a, b)
        raise ValueError("Overflow: inputs are too large for float division.") from None

    logger.debug("safe_divide(%r, %r) = %r", a, b, result)
    return result


if __name__ == "__main__":
    logging.basicConfig(level=logging.DEBUG, format="%(asctime)s [%(levelname)s] %(name)s: %(message)s")

    test_cases: list[tuple] = [
        (10, 3), (-7, 2), (0, 5), (1.5, 0.3),
        (10, 0), ("a", 2), (10, None), (True, 2),
        (float("inf"), 1), (1, float("nan")),
        (10**400, 1), (1+2j, 3), (1, True), (float("-inf"), 1),
    ]

    for a, b in test_cases:
        try:
            result = safe_divide(a, b)
            logger.info("safe_divide(%r, %r) = %r", a, b, result)
        except (TypeError, ValueError, ZeroDivisionError) as exc:
            logger.warning("safe_divide(%r, %r) raised %s: %s", a, b, type(exc).__name__, exc)
