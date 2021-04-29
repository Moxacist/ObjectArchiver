//
//  ObjectArchiver.m
//  ObjectArchiver
//
//  Created by moxacist on 2021/4/27.
//

#import "ObjectArchiver.h"
#import <objc/runtime.h>


@interface __PropertyType : NSObject

@property (nonatomic, assign, readwrite) const char *type;
@property (nonatomic, copy, readwrite) NSString *name;
@property (nonatomic, copy, readwrite) void (^decodeProperty)(NSObject *obj, NSCoder *coder);
@property (nonatomic, copy, readwrite) void (^encodeProperty)(NSObject *obj, NSCoder *coder);

- (instancetype)initWithName:(NSString *)name type:(const char *)type;

@end

@implementation __PropertyType

- (instancetype)initWithName:(NSString *)name type:(const char *)type {
    if (self = [super init]) {
        self.type = type;
        self.name = name;
        [self configArchiveFunction];
    }
    return self;
}

/// refrence: https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/ObjCRuntimeGuide/Articles/ocrtTypeEncodings.html#//apple_ref/doc/uid/TP40008048-CH100-SW1
- (void)configArchiveFunction {
    NSString *type = [[NSString stringWithUTF8String:self.type] substringToIndex:2];
    NSString *name = self.name;
    
    if ([@[@"Tc", @"TC", @"T*", @"T@", @"T#", @"T:"] containsObject:type]) {
        _decodeProperty = ^(NSObject *obj, NSCoder *coder) { [obj setValue:[coder decodeObjectForKey:name] forKey:name]; };
        _encodeProperty = ^(NSObject *obj, NSCoder *coder) { [coder encodeObject:[obj valueForKey:name] forKey:name]; };
    } else if ([type isEqualToString:@"Ti"] ||
               [type isEqualToString:@"TI"]) {
        _decodeProperty = ^(NSObject *obj, NSCoder *coder) { [obj setValue:@([coder decodeIntForKey:name]) forKey:name]; };
        _encodeProperty = ^(NSObject *obj, NSCoder *coder) { [coder encodeInt:[[obj valueForKey:name] intValue] forKey:name]; };
    } else if ([type isEqualToString:@"Ts"] ||
               [type isEqualToString:@"TS"]) {
        _decodeProperty = ^(NSObject *obj, NSCoder *coder) { [obj setValue:@([coder decodeInt32ForKey:name]) forKey:name]; };
        _encodeProperty = ^(NSObject *obj, NSCoder *coder) { [coder encodeInt32:[[obj valueForKey:name] intValue] forKey:name]; };
    } else if ([type isEqualToString:@"Tl"] ||
               [type isEqualToString:@"Tq"] ||
               [type isEqualToString:@"TL"] ||
               [type isEqualToString:@"TQ"]) {
        _decodeProperty = ^(NSObject *obj, NSCoder *coder) { [obj setValue:@([coder decodeInt64ForKey:name]) forKey:name]; };
        _encodeProperty = ^(NSObject *obj, NSCoder *coder) { [coder encodeInt64:[[obj valueForKey:name] intValue] forKey:name]; };
    } else if ([type isEqualToString:@"Tf"]) {
        _decodeProperty = ^(NSObject *obj, NSCoder *coder) { [obj setValue:@([coder decodeFloatForKey:name]) forKey:name]; };
        _encodeProperty = ^(NSObject *obj, NSCoder *coder) { [coder encodeFloat:[[obj valueForKey:name] floatValue] forKey:name]; };
    } else if ([type isEqualToString:@"Td"]) {
        _decodeProperty = ^(NSObject *obj, NSCoder *coder) { [obj setValue:@([coder decodeDoubleForKey:name]) forKey:name]; };
        _encodeProperty = ^(NSObject *obj, NSCoder *coder) { [coder encodeDouble:[[obj valueForKey:name] doubleValue] forKey:name]; };
    }
}

@end

#pragma mark - Utils

/// className: [__PropertyType]
static NSMutableDictionary *mc_classPropertyCache;

static NSSet <NSString *>* mc_ivarNames(Class cls) {
    NSMutableSet *ivarNames = @[].mutableCopy;
    unsigned int ivarCount = 0;
    Ivar *ivar_list = class_copyIvarList(cls, &ivarCount);
    for (int i = 0; i < ivarCount; i ++) {
        Ivar ivar = ivar_list[i];
        NSString *ivarName = [NSString stringWithUTF8String:ivar_getName(ivar)];
        [ivarNames addObject:ivarName];
    }
    return ivarNames;
}

static NSArray <__PropertyType *> *mc_propertyList(Class cls) {
    mc_classPropertyCache ? : (mc_classPropertyCache = @{}.mutableCopy);
    
    if (mc_classPropertyCache[NSStringFromClass(cls)]) {
        return mc_classPropertyCache[NSStringFromClass(cls)];
    }
    unsigned int count = 0;
    objc_property_t *prop_list = class_copyPropertyList(cls, &count);
    NSMutableArray *propsCache = @[].mutableCopy;
    
    NSSet *ivarNames = mc_ivarNames(cls);
    for (int i = 0; i < count; i ++) {
        objc_property_t prop = prop_list[i];
        NSString *propName = [NSString stringWithUTF8String:property_getName(prop)];
        if (![ivarNames containsObject:[NSString stringWithFormat:@"_%@", propName]]) {
            continue;
        }
        __PropertyType *type = [__PropertyType.alloc initWithName:propName type:property_getAttributes(prop)];
        [propsCache addObject:type];
    }
    free(prop_list);
    
    NSMutableArray *superPropsCache = @[].mutableCopy;
    Class superClass = [cls superclass];
    while (superClass != ObjectArchiver.class) {
        [superPropsCache addObjectsFromArray:mc_propertyList(superClass)];
        superClass = [superClass superclass];
    }
    [superPropsCache addObjectsFromArray:propsCache];
    
    mc_classPropertyCache[NSStringFromClass(cls)] = superPropsCache;
    
    return superPropsCache;
}


@implementation ObjectArchiver

#pragma mark - Public Method

- (NSData *)serializerationResult {
    id result = [NSKeyedArchiver archivedDataWithRootObject:self];
    return result;
}

+ (instancetype)deserializeWithData:(NSData *)data {
    ObjectArchiver *result = [NSKeyedUnarchiver unarchiveObjectWithData: data];
    return result;
}

#pragma mark - NSCoding

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super init];
    if (!self) { return self; }
    
    NSArray <__PropertyType *> *result = mc_propertyList(self.class);
    for (__PropertyType *type in result) {
        !type.decodeProperty ? : type.decodeProperty(self, coder);
    }
    return self;
}

- (void)encodeWithCoder:(nonnull NSCoder *)coder {
    NSArray <__PropertyType *> *result = mc_propertyList(self.class);
    for (__PropertyType *type in result) {
        !type.encodeProperty ? : type.encodeProperty(self, coder);
    }
}

@end


