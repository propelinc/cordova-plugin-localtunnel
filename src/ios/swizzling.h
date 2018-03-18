#ifndef swizzling_h
#define swizzling_h

// From: https://gist.github.com/defagos/1312fec96b48540efa5c
#import <objc/runtime.h>
#import <objc/message.h>


#define SwizzleSelector(clazz, selector, newImplementation, pPreviousImplementation) \
(*pPreviousImplementation) = (__typeof((*pPreviousImplementation)))class_swizzleSelector((clazz), (selector), (IMP)(newImplementation))

#define SwizzleClassSelector(clazz, selector, newImplementation, pPreviousImplementation) \
(*pPreviousImplementation) = (__typeof((*pPreviousImplementation)))class_swizzleClassSelector((clazz), (selector), (IMP)(newImplementation))

#define SwizzleSelectorWithBlock_Begin(clazz, selector) { \
SEL _cmd = selector; \
__block IMP _imp = class_swizzleSelectorWithBlock((clazz), (selector),
#define SwizzleSelectorWithBlock_End );}

#define SwizzleClassSelectorWithBlock_Begin(clazz, selector) { \
SEL _cmd = selector; \
__block IMP _imp = class_swizzleClassSelectorWithBlock((clazz), (selector),
#define SwizzleClassSelectorWithBlock_End );}

IMP class_swizzleSelector(Class clazz, SEL selector, IMP newImplementation);

IMP class_swizzleClassSelector(Class clazz, SEL selector, IMP newImplementation);

IMP class_swizzleSelectorWithBlock(Class clazz, SEL selector, id newImplementationBlock);

IMP class_swizzleClassSelectorWithBlock(Class clazz, SEL selector, id newImplementationBlock);

#endif /* swizzling_h */
