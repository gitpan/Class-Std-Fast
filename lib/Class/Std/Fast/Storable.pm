package Class::Std::Fast::Storable;

use version; $VERSION = qv('0.0.5');
use strict;
use warnings;
use Carp;

BEGIN {
    require Class::Std::Fast;
}

my $attributes_of_ref = {};
my @exported_subs = qw(
    Class::Std::Fast::ident
    Class::Std::Fast::DESTROY
    Class::Std::Fast::MODIFY_CODE_ATTRIBUTES
    Class::Std::Fast::AUTOLOAD
    Class::Std::Fast::_DUMP
    STORABLE_freeze
    STORABLE_thaw
    MODIFY_HASH_ATTRIBUTES
);

sub import {
    my $caller_package = caller;

    my %flags = (@_>=3) 
            ? @_[1..$#_]
            : (@_==2) && $_[1] >=2 
                ? ( constructor =>  'basic', cache => 0 )
                : ( constructor => 'normal', cache => 0);
    $flags{cache} = 0 if not defined $flags{cache};
    $flags{constructor} = 'normal' if not defined $flags{constructor};

    Class::Std::Fast::_init_class_cache( $caller_package )
        if ($flags{cache});

    no strict qw(refs);

    if ($flags{constructor} eq 'normal') {
        *{ $caller_package . '::new' } = \&Class::Std::Fast::new;
    }
    elsif ($flags{constructor} eq 'basic' && $flags{cache}) {
        *{ $caller_package . '::new' } = \&Class::Std::Fast::_new_basic_cache;
    }
    elsif ($flags{constructor} eq 'basic' && ! $flags{cache}) {
        *{ $caller_package . '::new' } = \&Class::Std::Fast::_new_basic;
    }
    elsif ($flags{constructor} eq 'none' ) {
        # nothing to do
    }
    else {
        die "Illegal import flags constructor => '$flags{constructor}', cache => '$flags{cache}'";
    }

    for my $name ( @exported_subs ) {
        my ($sub_name) = $name =~ m{(\w+)\z}xms;
        *{ $caller_package . '::' . $sub_name } = \&{$name};
    }
}

sub MODIFY_HASH_ATTRIBUTES {
    my $caller_package = $_[0];
    my @unhandled      = Class::Std::Fast::MODIFY_HASH_ATTRIBUTES(@_);
    my $i              = 0;
    $attributes_of_ref->{$caller_package} = {
        map {
            $_->{name} eq '????' ? '????_' . $i++ : $_->{name}
                => $_->{ref};
        } @{Class::Std::Fast::_get_internal_attributes($caller_package) || []}
    };
    return @unhandled;
}

sub STORABLE_freeze {
    # TODO do we really need to unpack @_? We're getting called for
    # Zillions of objects...
    my($self, $cloning) = @_;
    $self->can('STORABLE_freeze_pre')
        && $self->STORABLE_freeze_pre($cloning);

    my %frozen_attr; #to be constructed
    my $id           = ${$self};
    my @package_list = ref $self;
    my %package_seen = ( $package_list[0]  => 1 ); # ignore diamond/looped base classes :-)

    no strict qw(refs);
    PACKAGE:
    while( my $package = shift @package_list) {
        #make sure we add any base classes to the list of
        #packages to examine for attributes.

        # TODO ! $package_seen{$_}++ looks like a pretty slow test: it
        # performs ++ on every entry in @ISA.
        # Try something like 
        # "(not exists $package_seen{$_}) || $package_seen{$_}++" and
        # benchmark... 
        push @package_list, grep { ! $package_seen{$_}++; } @{"${package}::ISA"};

        #look for any attributes of this object for this package
        my $attr_ref = $attributes_of_ref->{$package} or next PACKAGE;

        # TODO replace inner my variable by $_ - faster...
        ATTR:              # examine attributes from known packages only
        for my $name ( keys %{$attr_ref} ) {
            #nothing to do if attr not set for this object
            exists $attr_ref->{$name}{$id} or next ATTR;
            #save the attr by name into the package hash
            $frozen_attr{$package}{ $name } = $attr_ref->{$name}{$id};
        }
    }
    $self->can('STORABLE_freeze_post')
        && $self->STORABLE_freeze_post($cloning, \%frozen_attr);

    return (Storable::freeze( \ (my $anon_scalar) ), \%frozen_attr);
}

sub STORABLE_thaw {
    # croak "must be called from Storable" unless caller eq 'Storable';
    # unfortunately, Storable never appears on the call stack.

    # TODO do we really need to unpack @_? We're getting called for
    # zillions of objects...
    my $self = shift;
    my $cloning = shift;
    my $frozen_attr_ref = $_[1]; # TODO Ha?? what's in $_[0], then ??? Check.

    $self->can('STORABLE_thaw_pre') 
        && $self->STORABLE_thaw_pre($cloning, $frozen_attr_ref);

    my $id = ${$self} ||= Class::Std::Fast::ID();
    PACKAGE:
    while( my ($package, $pkg_attr_ref) = each %{$frozen_attr_ref} ) {
        $self->isa($package)
            or croak "unknown base class '$package' seen while thawing "
                   . ref $self;
        ATTR:
        for my $name ( keys  %{$attributes_of_ref->{$package}} ) {
            # for known attrs...
            # nothing to do if frozen attr doesn't exist
            exists $pkg_attr_ref->{ $name } or next ATTR;
            # block attempts to meddle with existing objects
            exists $attributes_of_ref->{$package}{$name}{$id}
                and croak "trying to modify existing attributes for $package";

            # ok, set the attribute
            $attributes_of_ref->{$package}{$name}{$id}
                = delete $pkg_attr_ref->{ $name };
        }
        # this is probably serious enough to throw an exception.
        # however, TODO: it would be nice if the class could somehow
        # indicate to ignore this problem.
        %$pkg_attr_ref
        and croak "unknown attribute(s) seen while thawing class $package:"
                     . join q{, }, keys %$pkg_attr_ref;
    }

    $self->can('STORABLE_thaw_post') && $self->STORABLE_thaw_post($cloning);
}

1;

__END__

=pod

=head1 NAME

Class::Std::Fast::Storable - Fast Storable InsideOut objects

=head1 VERSION

This document describes Class::Std::Fast::Storable 0..0.5

=head1 SYNOPSIS

    package MyClass;

    use Class::Std::Fast::Storable;

    1;

    package main;

    use Storable qw(freeze thaw);

    my $thawn = freeze(thaw(MyClass->new()));

=head1 DESCRIPTION

Class::Std::Fast::Storable does the same as Class::Std::Storable
does for Class::Std. The API is the same as Class::Std::Storable's.

=head1 SUBROUTINES/METHODS

=head2 STORABLE_freeze

see method Class::Std::Storable::STORABLE_freeze

=head2 STORABLE_thaw

see method Class::Std::Storable::STORABLE_thaw

=head1 DIAGNOSTICS

see L<Class::Std>

and

see L<Class::Std::Storable>

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

see L<Class::Std>

=head1 RCS INFORMATIONS

=over

=item Last changed by

$Author: ac0v $

=item Id

$Id: Storable.pm 211 2007-12-02 03:57:28Z ac0v $

=item Revision

$Revision: 211 $

=item Date

$Date: 2007-12-02 04:57:28 +0100 (Sun, 02 Dec 2007) $

=item HeadURL

$HeadURL: http://svn.hyper-framework.org/Hyper/Class-Std-Fast/branches/2007-12-02/lib/Class/Std/Fast/Storable.pm $

=back

=head1 AUTHOR

Andreas 'ac0v' Specht  C<< <ACID@cpan.org> >>

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2007, Andreas Specht C<< <ACID@cpan.org> >>.
All rights reserved.

This module is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

=cut
