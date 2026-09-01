#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs the block inside @try/@catch and returns the caught NSException,
/// or nil if the block completed. Exists because AVAudioEngine raises
/// NSExceptions (e.g. installing a tap while an audio route change has the
/// input format in an invalid state) that Swift error handling cannot catch.
NSException * _Nullable VBTryCatch(void (NS_NOESCAPE ^ _Nonnull block)(void));

NS_ASSUME_NONNULL_END
