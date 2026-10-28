#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Error domain for exceptions converted by ``CBXPerformTrappingExceptions``.
/// `userInfo` carries `NSLocalizedDescription` (the exception's reason), plus
/// ``CBXExceptionNameKey`` and ``CBXExceptionCallStackKey``.
extern NSErrorDomain const CBXExceptionTrapErrorDomain;

/// The trapped `NSException`'s `name` (an `NSString`).
extern NSErrorUserInfoKey const CBXExceptionNameKey;
/// The trapped `NSException`'s `callStackSymbols` (an `NSArray<NSString *>`).
extern NSErrorUserInfoKey const CBXExceptionCallStackKey;

/// Runs `block`, converting any Objective-C `NSException` it raises into `error`.
///
/// **Why this file is the package's only Objective-C.** CoreML is an Objective-C
/// framework. It reports most failures as `NSError`, which Swift surfaces as a
/// normal `throws` — but some accelerator faults are raised with `@throw` instead
/// (e.g. the Neural Engine's `E5RT … No memory object bound to port`). Swift has no
/// `catch` for `NSException`: it unwinds straight past every `do/catch` into
/// `std::terminate`, killing the process. `@try/@catch` exists only in Objective-C,
/// so trapping such a fault requires exactly this shim.
///
/// **Caveat.** An `NSException` out of a framework leaves that framework's internal
/// state undefined in general, so this is not a licence to retry in place. It is used
/// here only to demote a fatal fault to a failed *utterance*: the enclosing synthesis
/// is abandoned, per-call scratch is discarded (the T3 `MLState` is minted per
/// `generate`), and the next request starts clean.
///
/// @param block The work to run. Never escapes.
/// @param error On an exception, set to a `CBXExceptionTrapErrorDomain` error.
/// @return `YES` if `block` completed, `NO` if it raised.
BOOL CBXPerformTrappingExceptions(NS_NOESCAPE void (^block)(void),
                                  NSError *__autoreleasing _Nullable *_Nullable error);

NS_ASSUME_NONNULL_END
