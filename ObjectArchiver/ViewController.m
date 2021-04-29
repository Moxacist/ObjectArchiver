//
//  ViewController.m
//  ObjectArchiver
//
//  Created by moxacist on 2021/4/27.
//

#import "ViewController.h"
#import "ObjectArchiver.h"

@interface Animal : ObjectArchiver

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

@end

@interface ViewController ()

@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    [self test];
}


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


@end
