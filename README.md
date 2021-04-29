### 先看一个现象

使用 YYModel 对嵌套模型进行解归档：

```objective-c
@interface Animal : NSObject

@end

@implementation Animal

@end

@interface Cat : Animal

@property (nonatomic, copy) NSString *name;

@end

@implementation Cat

@end

@interface Person : Animal

@property (nonatomic, strong) NSArray <Animal *>*pets;

@end

@implementation Person

+ (nullable NSDictionary<NSString *, id> *)modelContainerPropertyGenericClass {
    return @{@"pets": Animal.class};
}

@end

  
- (void)test {
    Cat *cat = Cat.new;
    cat.name = @"miao";
    
    Person *person = Person.new;
    person.pets = @[cat];
    
    NSData *data = person.yy_modelToJSONData;
    Person *reborn = [Person yy_modelWithJSON:data];
    
    NSLog(@"the name of the cat is : %@", [reborn.pets.firstObject valueForKey:@"name"]);
  	// the name of the cat is :(null)
}
```
从打印结果可以看出，宠物 `Cat` 的名字丢失了，而实际上此时反序列化后的  `pets` 都是普通的 `Animal` ，没有所谓的 `Cat`。至于丢失的原因下面再说。


### 问题背景

之前有模仿开源项目写一个 OC 热修复功能，其中脚本部分的工作是将 OC 代码解析成语法树对象，再将语法树对象序列化成二进制文件上传到服务端。因为语法树中的每个子对象语义不同，导致生成的语法树对象嵌套逻辑比较复杂，如下所示：

```objective-c
@interface Node : NSObject

@property (nonatomic, assign) BOOL withSemicolon;

@end
  
@interface MethodImpNode : Node

@property (nonatomic, strong) MethodDeclareNode *declare;
@property (nonatomic, strong) ScopeImpNode *scopeImp;

@end

@interface ClassNode : Node

@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *superClassName;
@property (nonatomic, strong) NSMutableArray <NSString *> *protocols;
@property (nonatomic, strong) NSMutableArray <PropertyDeclareNode *> *properties;
@property (nonatomic, strong) NSMutableArray <TypeVariableNode *> *privateVariables;
@property (nonatomic, strong) NSMutableArray <MethodImpNode *> *methods;
@end 

......
......
  
@interface ASTResult : WYCodingObject

+ (instancetype)shared;

@property (nonatomic, strong) NSMutableArray <Node *>*nodes;

@end
```

而现在的需求是将一个 `ASTResult` 对象序列化，下面的问题也是以此为背景展开。



### 使用 YYModel

由于之前一直使用 `YYModel` 作为对象序列化和反序列的方式，所以这里第一时间想到的也是它。可是使用 YYModel 时却遇到了两个问题：

1. 对于实例中的对象数组，需要为其编写映射关系，例如 `ASTResult.Nodes`
2. 即使写了映射关系，也会出现子类化特性丢失的情况，像一开始那样。

出现子类特性丢失的原因其实很简单，`YYModel` 做反序列时会根据映射关系生成 `Animal` 对象，再生成 `_YYModelMeta`，而赋值的时候会根据 `_YYModelMeta` 的属性进行赋值，而 `Animal` 是无法找到 `name` 的，所以反序列化之后为空。部分代码如下所示：

```objective-c
_YYModelMeta *modelMeta = [_YYModelMeta metaWithClass:object_getClass(self)];
if (modelMeta->_keyMappedCount >= CFDictionaryGetCount((CFDictionaryRef)dic)) {
    CFDictionaryApplyFunction((CFDictionaryRef)dic, ModelSetWithDictionaryFunction, &context);
    if (modelMeta->_keyPathPropertyMetas) {
        CFArrayApplyFunction((CFArrayRef)modelMeta->_keyPathPropertyMetas,
                             CFRangeMake(0, CFArrayGetCount((CFArrayRef)modelMeta->_keyPathPropertyMetas)),
                             ModelSetWithPropertyMetaArrayFunction,
                             &context);
    }
    if (modelMeta->_multiKeysPropertyMetas) {
        CFArrayApplyFunction((CFArrayRef)modelMeta->_multiKeysPropertyMetas,
                             CFRangeMake(0, CFArrayGetCount((CFArrayRef)modelMeta->_multiKeysPropertyMetas)),
                             ModelSetWithPropertyMetaArrayFunction,
                             &context);
    }
} else {
    CFArrayApplyFunction((CFArrayRef)modelMeta->_allPropertyMetas,
                         CFRangeMake(0, modelMeta->_keyMappedCount),
                         ModelSetWithPropertyMetaArrayFunction,
                         &context);
}
```

到这里，基本放弃 `YYModel` 了，开始寻找其他方法。



### 使用解归档

除了 `YYModel` 外，最常见的应该应该是系统自带的解归档。但是有个非常麻烦的点，就是需要编写 `NSCoding` 的协议方法，针对每个属性进行解档和归档。

而对于我们这个场景，如果按照默认的写法，为这几十个类逐个添加协议实现，就显得非常愚蠢了。所以想法是看能不能利用 `runtime` 获取对象属性和属性类型，进行解档和归档，按照这个逻辑，以下分为如下几个步骤：

**1. 编写一个父类，提供解归档方法**

```objective-c
@interface ObjectArchiver : NSObject

/// 序列化结果
- (NSData *)serializerationResult;

/// 反序列化结果
+ (instancetype)deserializeWithData:(NSData *)data;

@end
```

**2. 根据 Class 获取属性标签列表**

```objective-c
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
```

这里代码看起来有点多，主要做的事如下：

	1. 判断 `mc_classPropertyCache` 缓存中有没有该类，有就返回
	2. 获取该类的属性列表，生成 `__PropertyType` 对象，如果该属性没有对应的变量，就排除掉
	3. 递归寻找父类的列表，直到 `ObjectArchiver` 这个对象为止，将属性添加在列表里
	4. 缓存最后的列表到 `mc_classPropertyCache` 中

**3. 为属性标签添加解归档 block**

```objective-c
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
```

这部分是根据函数类型标签获取具体的解归档函数，这里引用的是 [Type Encodings](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/ObjCRuntimeGuide/Articles/ocrtTypeEncodings.html#//apple_ref/doc/uid/TP40008048-CH100-SW1) 。这里解归档函数并不是逐个匹配所有类型，但是涵盖了大部分。

**4. 用 Person.pets 测试下**

```objective-c
- (void)test {
    Cat *cat = Cat.new;
    cat.name = @"miao";
    
    Person *person = Person.new;
    person.pets = @[cat];
    
    NSData *data = [person serializerationResult];
    Person *reborn = [Person deserializeWithData:data];
    
    NSLog(@"the name of the cat is : %@", [reborn.pets.firstObject valueForKey:@"name"]);
      // the name of the cat is : miao
}
```

这里可以看出已经达到预期效果。具体 Demo 查看 [ObjectArchiver](https://github.com/Moxacist/ObjectArchiver)。



### 目前仍有的问题

1. 对于 `Associate` 关联的属性没做处理