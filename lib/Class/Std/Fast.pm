package Class::Std::Fast;

use version; $VERSION = qv('0.0.3');
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

my %attribute;
my %optimization_level_of = ();
my $instance_counter      = 1;

sub ID_GENERATOR_REF { return \$instance_counter };

my @exported_subs = qw(
    new
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

sub import {
    my $caller_package = caller;
    _set_optimization_level($caller_package =>  $_[1]);
    no strict qw(refs);
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
#                    return $_[0];
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

sub new {
    # stop here if we're running really fast ...
    # don't even allocate extra space for my variable ...

    # maybe replace by exporting the sub requested into namespace -
    # could be a bit faster ...
    return bless \(my $anon_scalar = $instance_counter++), $_[0]
        if exists $optimization_level_of{$_[0]}
            && $optimization_level_of{$_[0]} > 1;

    no strict 'refs';

    # Yup, that's duplicate code. But that's the price for speed.
    my $new_obj    = bless \(my $another_anon_scalar = $instance_counter++), $_[0];

    # Symbol Class:: must exist...
    croak "Can't find class $_[0]" if ! keys %{ $_[0] . '::' };

    Class::Std::initialize(); # Ensure run-time (and mod_perl) setup is done

    # extra safety only required if we actually care of arguments ...
    croak "Argument to $_[0]\->new() must be hash reference"
        if ($#_) && ref $_[1] ne 'HASH';

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
    push @_, ${$_[0]};
    no strict qw(refs);

    # Shortcut: check @ISA - saves us a method call if 0...
    DEMOLISH: for my $base_class ($class, @{"$class\::ISA"} == 0 ? () : Class::Std::_hierarchy_of($class) ) {
        # maybe use exists &$base_class::DEMOLISH ? should be a bit faster...
        if ( my $demolish_ref = *{"$base_class\::DEMOLISH"}{CODE} ) {
            # call with & to pass aruments in @_ - dirty but fast...
            &{$demolish_ref};
        }
        delete $_->{ref}->{$ident} for @{$attribute{$class}};
    }
    return;

}

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

This document describes Class::Std::Fast 0.01

=head1 SYNOPSIS

    package MyClass;

    use Class::Std::Fast;

    1;

    package main;

    MyClass->new();

=head1 DESCRIPTION

Class::Std::Fast allows you to use the beautifull API of Class::Std in a
faster way than Class::Std does.

You can get the objects ident via scalarifiyng your object.

Getting the objects ident is still possible via the ident method, but it's
faster to scalarify your object.

=head1 SUBROUTINES/METHODS

=head2 new

The constructor acts like Class::Std's constructor. If your Class used
Class::Std::Fast with a performance level greater than 1 all BUILD and START
methods are ignored.

    package FastObject;
    use Class::Std::Fast;

    1;
    my $fast_obj = FastObject->new();

    # or if you don't need any BUILD or START methods
    package FasterObject;
    use Class::Std::Fast qw(2);

    1;

    my $faster_obj = FasterObject->new();

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

=head1 DIAGNOSTICS

see L<Class::Std>

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

=item * No runtime initialization with "use Class::Std::Fast qw(2);"

When eval'ing Class::Std::Fast based classes with extra optimization enabled,
make sure the last line is

 Class::Std::Fast::initialize();

In contrast to Class::Std, Class::Std::Fast performs no run-time
initialization when optimization >1 is enabled, so your code has to do it
itself.

CUMULATIVE, PRIVATE, RESTRICTED and anticumulative methods won't work if you
leave out this line.

=back

=head1 RCS INFORMATIONS

=over

=item Last changed by

$Author: ac0v $

=item Id

$Id: Fast.pm 179 2007-11-11 21:03:02Z ac0v $

=item Revision

$Revision: 179 $

=item Date

$Date: 2007-11-11 22:03:02 +0100 (Sun, 11 Nov 2007) $

=item HeadURL

$HeadURL: http://svn.hyper-framework.org/Hyper/Class-Std-Fast/branches/2007-11-11/lib/Class/Std/Fast.pm $

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
