package Class::Std::Fast;

use version; $VERSION = qv('0.0.5');
use strict;
use warnings;
use Carp;

BEGIN {
    require Class::Std;
    no strict qw(refs);
    for my $sub ( qw(MODIFY_CODE_ATTRIBUTES AUTOLOAD _mislabelled initialize) ) {
        *{$sub} = \&{'Class::Std::' . $sub};
    }
}

my %object_cache_of = ();
my %do_cache_class_of = ();

my %attribute;
my %optimization_level_of = ();
my $instance_counter      = 1;

# use () prototype to indicate to perl that it does not need to prepare an
# argument stack
sub OBJECT_CACHE_REF () { return \%object_cache_of };
sub ID_GENERATOR_REF () { return \$instance_counter };

my @exported_subs = qw(
    ident
    DESTROY
    _DUMP
    AUTOLOAD
);
my @exported_extension_subs = qw(
    MODIFY_CODE_ATTRIBUTES
    MODIFY_HASH_ATTRIBUTES
);
sub _get_internal_attributes {
    croak q{you can't call this method in your namespace}
        if 0 != index caller, 'Class::Std::';
    return $attribute{$_[-1]};
}

sub _set_optimization_level {
    $optimization_level_of{$_[0]} = $_[1] || 1;
}

# Prototype allows perl to inline ID
sub ID() {
    return $instance_counter++;
}

sub ident ($) {
    return ${$_[0]};
}

sub _init_class_cache {
    $do_cache_class_of{ $_[0] } = 1;
    $object_cache_of{ $_[0] } ||= [];
}

sub import {
    my $caller_package = caller;

    my %flags = (@_>=3) 
            ? @_[1..$#_]
            : (@_==2) && $_[1] >=2 
                ? ( constructor =>  'basic', cache => 0 )
                : ( constructor => 'normal', cache => 0);
    $flags{cache} = 0 if not defined $flags{cache};
    $flags{constructor} = 'normal' if not defined $flags{constructor};

    _init_class_cache( $caller_package )
        if ($flags{cache});

    no strict qw(refs);

    if ($flags{constructor} eq 'normal') {
        *{ $caller_package . '::new' } = \&new;
    }
    elsif ($flags{constructor} eq 'basic' && $flags{cache}) {
        *{ $caller_package . '::new' } = \&_new_basic_cache;
    }
    elsif ($flags{constructor} eq 'basic' && ! $flags{cache}) {
        *{ $caller_package . '::new' } = \&_new_basic;
    }
    elsif ($flags{constructor} eq 'none' ) {
        # nothing to do
    }
    else {
        croak "Illegal import flags constructor => '$flags{constructor}', cache => '$flags{cache}'";
    }

    for my $sub ( @exported_subs ) {
        *{ $caller_package . '::' . $sub } = \&{$sub};
    }
    for my $sub ( @exported_extension_subs ) {
        my $target = $caller_package . '::' . $sub;
        my $real_sub = *{ $target }{CODE} || sub { return @_[2..$#_] };
        no warnings qw(redefine);
        *{ $target } = sub {
            my ($package, $referent, @unhandled) = @_;
            for my $handler ($sub, $real_sub) {
                next if ! @unhandled;
                @unhandled = $handler->($package, $referent, @unhandled);
            }
            return @unhandled;
        };
    }
}

sub MODIFY_HASH_ATTRIBUTES {
    my ($package, $referent, @attrs) = @_;
    for my $attr (@attrs) {
        next if $attr !~ m/\A ATTRS? \s* (?: \( (.*) \) )? \z/xms;
        my ($default, $init_arg, $getter, $setter, $name);
        if (my $config = $1) {
            $default  = Class::Std::_extract_default($config);
            $name     = Class::Std::_extract_name($config);
            $init_arg = Class::Std::_extract_init_arg($config) || $name;
            if ($getter = Class::Std::_extract_get($config) || $name) {
                no strict 'refs';
                *{$package.'::get_'.$getter} = sub {
                    return $referent->{${$_[0]}};
                }
            }
            if ($setter = Class::Std::_extract_set($config) || $name) {
                no strict 'refs';
                *{$package.'::set_'.$setter} = sub {
                    $referent->{${$_[0]}} = $_[1];
                    return;
                }
            }
            if (defined($optimization_level_of{$package}) 
                && $optimization_level_of{$package} >= 3) {
                 no strict qw(refs);
		         *{ $package . '::___' . $getter } = \$attr;
            }
        }
        undef $attr;
        push @{$attribute{$package}}, {
            ref      => $referent,
            default  => $default,
            init_arg => $init_arg,
            name     => $name || $init_arg || $getter || $setter || '????',
        };
    }
    return grep {defined} @attrs;
}

sub _DUMP {
    my ($self) = @_;
    my $id = ${$self};

    my %dump;
    for my $package (keys %attribute) {
        my $attr_list_ref = $attribute{$package};
        for my $attr_ref ( @{$attr_list_ref} ) {
            next if !exists $attr_ref->{ref}{$id};
            $dump{$package}{$attr_ref->{name}} = $attr_ref->{ref}{$id};
        }
    }

    require Data::Dumper;
    my $dump = Data::Dumper::Dumper(\%dump);
    $dump =~ s/^.{8}//gxms;
    return $dump;
}

sub _new_basic {
    return bless \(my $anon_scalar = $instance_counter++), $_[0];
}

sub _new_basic_cache {
    return pop @{ $object_cache_of{ $_[0] }}
        || bless \(my $anon_scalar = $instance_counter++), $_[0];
}

sub new {
    no strict 'refs';

    # Symbol Class:: must exist...
    croak "Can't find class $_[0]" if ! keys %{ $_[0] . '::' };

    Class::Std::initialize(); # Ensure run-time (and mod_perl) setup is done

    # extra safety only required if we actually care of arguments ...
    croak "Argument to $_[0]\->new() must be hash reference"
        if ($#_) && ref $_[1] ne 'HASH';

    # try cache first if caching is enabled for this class
    my $new_obj = exists($do_cache_class_of{ $_[0] })
        && pop @{ $object_cache_of{ $_[0] } }
        || bless \(my $another_anon_scalar = $instance_counter++), $_[0];

    my (@missing_inits, @suss_keys, @start_methods);
    $_[1] ||= {};
    my %arg_set;
    BUILD: for my $base_class (Class::Std::_reverse_hierarchy_of($_[0])) {
        my $arg_set = $arg_set{$base_class}
            = { %{$_[1]}, %{$_[1]->{$base_class}||{}} };

        # Apply BUILD() methods ...
        {
        no warnings 'once';
        if (my $build_ref = *{$base_class.'::BUILD'}{CODE}) {
            $build_ref->($new_obj, ${$new_obj}, $arg_set);
        }
        if (my $init_ref = *{$base_class.'::START'}{CODE}) {
            push @start_methods, sub {
                $init_ref->($new_obj, ${$new_obj}, $arg_set);
            };
        }
    }

    # Apply init_arg and default for attributes still undefined ...
    my $init_arg;
        INIT:
        for my $attr_ref ( @{$attribute{$base_class}} ) {
            defined $attr_ref->{ref}{${$new_obj}} and next INIT;
            # Get arg from initializer list...
            if (defined $attr_ref->{init_arg} && exists $arg_set->{$attr_ref->{init_arg}}) {
                $attr_ref->{ref}{${$new_obj}} = $arg_set->{$attr_ref->{init_arg}};
                next INIT;
            }
            elsif (defined $attr_ref->{default}) {
                # Or use default value specified...
                $attr_ref->{ref}{${$new_obj}} = eval $attr_ref->{default};

                $@ and $attr_ref->{ref}{${$new_obj}} = $attr_ref->{default};
                next INIT;
            }
            if (defined $attr_ref->{init_arg}) {
                # Record missing init_arg ...
                push @missing_inits,
                     "Missing initializer label for $base_class: "
                     . "'$attr_ref->{init_arg}'.\n";
                push @suss_keys, keys %{$arg_set};
            }
        }
    }

    croak @missing_inits, _mislabelled(@suss_keys),
          'Fatal error in constructor call'
                if @missing_inits;

    $_->() for @start_methods;

    return $new_obj;
}

# DESTROY looks a bit cryptic, thus needs to be explained...
#
# It performs the following tasks:
# - traverse the @ISA hierarchy
#   - for every base class
#       - call DEMOLISH if there is such a method with $_[0], ${$_[0]} as
#         arguments (read as: $self, $id).
#       - delete the element with key ${ $_[0] } from all :ATTR hashes
sub DESTROY {
    my $ident = ${$_[0]};
    my $class = ref $_[0];
    push @_, $ident;

    no strict qw(refs);

    # Shortcut: check @ISA - saves us a method call if 0...
    DEMOLISH: for my $base_class (scalar @{ "$class\::ISA"}
        ? Class::Std::_hierarchy_of($class) 
        : ($class) ) {
        # call by & to tell perl that it doesn't need to put up a new argument
        # stack
        &{"$base_class\::DEMOLISH"} 
            if ( exists(&{"$base_class\::DEMOLISH"}) );

        # postfix for saves a block
        delete $_->{ref}->{$ident} for (@{$attribute{$base_class}});
    }

    # call with @_ as arguments - dirty but fast...
    &Class::Std::Fast::_cache if exists($do_cache_class_of{ $class });

    return;
}

sub _cache {
    push @{ $object_cache_of{ ref $_[0] }}, bless $_[0], ref $_[0];
}

# clean out cache method to prevent it being called in global destruction
sub END {
    no warnings qw(redefine);
    *Class::Std::Fast::_cache = sub {};
}

# Override can to make it work with AUTOMETHODs
# Slows down can() for all objects
{
    my $real_can = \&UNIVERSAL::can;
    no warnings qw(redefine once);
    *UNIVERSAL::can = sub {
        my ($invocant, $method_name) = @_;

        if (my $sub_ref = $real_can->(@_)) {
            return $sub_ref;
        }

        for my $parent_class ( Class::Std::_hierarchy_of(ref $invocant || $invocant) ) {
            no strict 'refs';
            if (my $automethod_ref = *{$parent_class.'::AUTOMETHOD'}{CODE}) {
                local $CALLER::_ = $_;
                local $_ = $method_name;
                if (my $method_impl = $automethod_ref->(@_)) {
                    return sub { my $inv = shift; $inv->$method_name(@_) }
                }
            }
        }

        return;
    };
}

1;

__END__

=pod

=head1 NAME

Class::Std::Fast - faster but less secure than Class::Std

=head1 VERSION

This document describes Class::Std::Fast 0.0.5

=head1 SYNOPSIS

    package MyClass;

    use Class::Std::Fast;

    1;

    package main;

    MyClass->new();

=head1 DESCRIPTION

Class::Std::Fast allows you to use the beautifull API of Class::Std in a
faster way than Class::Std does.

You can get the object's ident via scalarifiyng your object.

Getting the objects ident is still possible via the ident method, but it's
faster to scalarify your object.

=head1 SUBROUTINES/METHODS

=head2 new

The constructor acts like Class::Std's constructor. For extended constructors
see L<Constructors> below.

    package FastObject;
    use Class::Std::Fast;

    1;
    my $fast_obj = FastObject->new();


=head2 ident

If you use Class::Std::Fast you shouldn't use this method. It's only existant
for downward compatibility.

    # insted of
    my $ident = ident $self;

    # use
    my $ident = ${$self};

=head2 initialize

    Class::Std::Fast::initialize();

Imported from L<Class::Std>. Please look at the documentation from
L<Class::Std> for more details.

=head2 Method for accessing Class::Std::Fast's internals

Class::Std::Fast exposes some of it's internals to allow the construction
of Class::Std::Fast based objects from outside the auto-generated
constructors.

You should never use these methods for doing anything else. In fact you
should not use these methods at all, unless you know what you're doing.

=head2 ID

Returns an ID for the next object to construct.

If you ever need to override the constructor created by Class::Std::Fast,
be sure to use Class::Std::Fast::ID as the source for the ID to assign to
your blessed scalar.

More precisely, you should construct your object like this:

    my $self = bless \do { my $foo = Class::Std::Fast::ID } , $class;

Every other method of constructing Class::Std::Fast - based objects will lead
to data corruption (duplicate object IDs).

=head2 ID_GENERATOR_REF

Returns a reference to the ID counter scalar.

The current value is the B<next> object ID !

You should never use this method unless you're trying to create
Class::Std::Fast objects from outside Class::Std::Fast (and possibly outside
perl).

In case you do (like when creating perl objects in XS code), be sure to
post-increment the ID counter B<after> creating an object, which you may do
from C with

    sv_inc( SvRV(id_counter_ref) )

=head2 OBJECT_CACHE_REF

Returns a reference to the object cache.

You should never use this method unless your're trying to (re-)create
Class::Std::Fast objects from outside Class::Std::Fast (and possibly outside
perl).

See <L/EXTENSIONS TO Class::Std> for a description of the object cache
facility.

=head1 EXTENSIONS TO Class::Std

=head2 Constructors

Class::Std::Fast allows the user to chose between several constructor
options.

=over

=item * Standard constructor

No special synopsis. Acts like Class::Std's constructor

=item * Basic constructor

 use Class::Std::Fast qw(2);
 use Class::Std::Fast constructor => 'basic';

Does not call BUILD and START (and does not walk down the inheritance
hierarchy calling BUILD and START).

Does not perform any attribute initializations.

Really fast, but very basic.

=item * No constructor
 
 use Class::Std::Fast qw(3);
 use Class::Std::Fast constructor => 'none';

No constructor is exported into the calling class.

The recommended usage is:

 use Class::Std::Fast constructor => none;
 sub new {
     my $self = bless \do { my $foo = Class::Std::Fast::ID } , $_[0];
     # do what you need to do after that
 }

If you use the Object Cache (see below) the recommended usage is:

 use Class::Std::Fast constructor => 'none', cache => 1;
 sub new {
     my $self = pop @{ Class::Std::Fast::OBJECT_CACHE_REF()->{ $_[0] } }
        || bless \do { my $foo = Class::Std::Fast::ID() } , $_[0];
 }

=back

=head2 Object Cache

=head3 Synopsis

 use Class::Std::Fast cache => 1;

=head3 Description

While inside out objects are basically an implementation of the Flyweight
Pattern (object data is stored outside the object), there's still some aspect
missing: object reuse. While Class::Std::Fast does not provide flyweights
in the classical sense (one object re-used again and again), it provides
something close to it: An object cache for re-using destroyed objects.

The object cache is implemented as a simple hash with the class names of the
cached objects as keys, and a list ref of cached objects as values.

The object cache is filled by the DESTROY method exported into all
Class::Std::Fast based objects: Instead of actually destroying the blessed
scalar reference (Class::Std::Fast based objects are nothing more), the
object to be destroyed is pushed it's class' object cache.

new() in turn does not need to create a new blessed scalar, but can just pop
one off the object cache (which is a magnitude faster).

Using the object cache is recommended for persistent applications (like
running under mod_perl), or applications creating, destroying and again
creating lots of Class::Std::Fast based objects.

The exported constructor automatically uses the Object Cache when caching is
enabled by setting the cache import fla to a true value.

For an example of a user-defined constructor see L</Constructors> above.

=head3 Memory overhead

The object cache trades speed for memory. This is very perlish way for
adressing performance issues, but may cause your application to blow up
if you're short of memory.

On a 32bit Linux, Devel::Size reports 44 bytes for a Class::Std::Fast based
object - so a cache containing 1 000 000 (one million) of objects needs
around 50MB of memory (Devel Size only reports the memory use it can see -
the actual usage is system dependent and something between 4 and 32 bytes
more).

If you are anxious about falling short of memory, only enable caching for
those classes whose objects you now to be frequently created and destroyed,
and leave it off for the less frequently used classes - this gives you both
speed benefits, and avoids holding a cache of object that will never be
needed again.

=head1 DIAGNOSTICS

see Class::Std.

Additional diagnostics are:

=over

=item * 

=back

=head1 CONFIGURATION AND ENVIRONMENT

=head1 DEPENDENCIES

=over

=item *

L<version>

=item *

L<Class::Std>

=item *

L<Carp>

=back

=head1 INCOMPATIBILITIES

see L<Class::Std>

=head1 BUGS AND LIMITATIONS

=over

=item * You can't use the :SCALARIFY attribute for your Objects.

We use an increment for building identifiers and not Scalar::Util::refaddr
like Class::Std.

=item * Inheriting from non-Class::Std::Fast modules does not work

You cannot inherit from non-Class::Std::Fast classes, not even if you
overwrite the default constructor. To be more precise, you cannot inherit
from classes which use something different from numeric blessed scalar
references as their objects. Even so inheriting from similarly contructed
classes like Object::InsideOut could work, you would have to make sure that
object IDs cannot be duplicated. It is therefore strongly discouraged to
build classes with Class::Std::Fast derived from non-Class::Std::Fast classes.

If you really need to inherit from non-Class::Std::Fast modules, make sure
you use Class::Std::Fast::ID as described above for creating objects.

=item * No runtime initialization with constructor => 'basic' / 'none'

When eval'ing Class::Std::Fast based classes using the basic constructor,
make sure the last line is

 Class::Std::Fast::initialize();

In contrast to Class::Std, Class::Std::Fast performs no run-time
initialization when the basic constructor is enabled, so your code has to
do it itself.

The same holds true for constructor => 'none', of course.

CUMULATIVE, PRIVATE, RESTRICTED and anticumulative methods won't work if you
leave out this line.

=back

=head1 RCS INFORMATIONS

=over

=item Last changed by

$Author: ac0v $

=item Id

$Id: Fast.pm 211 2007-12-02 03:57:28Z ac0v $

=item Revision

$Revision: 211 $

=item Date

$Date: 2007-12-02 04:57:28 +0100 (Sun, 02 Dec 2007) $

=item HeadURL

$HeadURL: http://svn.hyper-framework.org/Hyper/Class-Std-Fast/branches/2007-12-02/lib/Class/Std/Fast.pm $

=back

=head1 AUTHORS

Andreas 'ac0v' Specht  C<< <ACID@cpan.org> >>

Martin Kutter C<< <martin.kutter@fen-net.de> >>

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2007, Andreas Specht C<< <ACID@cpan.org> >>.
All rights reserved.

This module is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

=cut
