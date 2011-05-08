package Routes::Tiny::Pattern;

use strict;
use warnings;

use Routes::Tiny::Match;

my $TOKEN = '[^\/()]+';

sub new {
    my $class = shift;

    my $self = {captures => [], constraints => {}, @_};
    bless $self, $class;

    return $self;
}

sub name { return shift->{name} }

sub match {
    my $self = shift;
    my ($path, %args) = @_;

    return unless $self->_match_method($args{method});

    $self->_prepare_pattern;

    unless ($path =~ m{ ^ / }xms) {
        $path = "/$path";
    }

    my $pattern = $self->{pattern};

    my @captures = ($path =~ m/ $pattern /xms);
    return unless @captures;

    my $params = {};
    $params = {%{$self->{defaults} || {}}};

    foreach my $capture (@{$self->{captures}}) {
        last unless @captures;

        my $value = shift @captures;

        if (defined($value) || !exists $params->{$capture}) {
            $params->{$capture} = $value;
        }
    }

    return $self->_build_match(name => $self->name, params => $params);
}

sub build_path {
    my $self   = shift;
    my %params = @_;

    $self->_prepare_pattern;

    my @parts;

    my $optional_depth = 0;
    my $trailing_slash = 0;

    foreach my $group_part (@{$self->{parts}}) {
        my $path = '';

        foreach my $part (@$group_part) {
            my $type = $part->{type};
            my $name = $part->{name};

            if ($type eq 'capture') {
                if ($part->{level} && exists $params{$name}) {
                    $optional_depth = $part->{level};
                }

                if (!exists $params{$name}) {
                    next
                      if $part->{level} && $part->{level} > $optional_depth;

                    if (   exists $self->{defaults}
                        && exists $self->{defaults}->{$name})
                    {
                        $params{$name} = $self->{defaults}->{$name};
                    }
                    else {
                        Carp::croak("Required param '$part->{name}' was not "
                              . "passed when building a path");
                    }
                }

                my $param = $params{$name};

                if (defined(my $constraint = $part->{constraint})) {
                    Carp::croak("Param '$name' fails a constraint")
                      unless $param =~ m/^ $constraint $/xms;
                }

                $path .= $param;
            }
            elsif ($type eq 'glob') {
                if (!exists $params{$name}) {
                    if (   exists $self->{defaults}
                        && exists $self->{defaults}->{$name})
                    {
                        $params{$name} = $self->{defaults}->{$name};
                    }
                    elsif ($part->{optional}) {
                        next;
                    }
                    else {
                        Carp::croak("Required glob param '$part->{name}' was not "
                              . "passed when building a path");
                    }
                }

                $path .= $params{$name};
            }
            elsif ($type eq 'text') {
                $path .= $part->{text};
            }

            $trailing_slash = $part->{trailing_slash};
        }

        if ($path ne '') {
            push @parts, $path;
        }
    }

    my $path = q{/} . join q{/} => @parts;

    if ($path ne '/' && $trailing_slash) {
        $path .= q{/};
    }

    return $path;
}

sub _match_method {
    my $self = shift;
    my ($value) = @_;

    my $method = $self->{method};

    return 1 unless defined $method;

    return unless defined $value;

    my $methods = $method;
    $methods = [$methods] unless ref $methods eq 'ARRAY';

    return !!scalar grep { $_ eq $value } @{$methods};
}

sub _prepare_pattern {
    my $self = shift;

    return $self->{pattern} if ref $self->{pattern} eq 'Regexp';

    my $pattern = $self->{pattern};
    if ($pattern !~ m{ \A / }xms) {
        $pattern = q{/} . $pattern;
    }

    $self->{captures} = [];

    my $re        = q{};
    my $par_depth = 0;
    my @parts;

    my $part;

    pos $pattern = 0;
    while (pos $pattern < length $pattern) {
        if ($pattern =~ m{ \G \/ }gcxms) {
            if ($part) {
                push @parts, $part;
            }

            $part = [];
            $re .= q{/};
        }
        elsif ($pattern =~ m{ \G :($TOKEN) }gcxms) {
            my $name = $1;
            my $constraint;

            if (exists $self->{constraints}->{$name}) {
                $constraint = $self->{constraints}->{$name};
                $re .= "($constraint)";
            }
            else {
                $re .= '([^\/]+)';
            }

            push @$part,
              { type       => 'capture',
                name       => $name,
                constraint => $constraint ? qr/^ $constraint $/xms : undef,
                level      => $par_depth
              };

            push @{$self->{captures}}, $name;
        }
        elsif ($pattern =~ m{ \G \*($TOKEN) }gcxms) {
            my $name = $1;

            $re .= '(.*)';

            push @$part, {type => 'glob', name => $name};

            push @{$self->{captures}}, $name;
        }
        elsif ($pattern =~ m{ \G ($TOKEN) }gcxms) {
            my $text = $1;
            $re .= quotemeta $text;

            push @$part, {type => 'text', text => $text};
        }
        elsif ($pattern =~ m{ \G \( }gcxms) {
            $par_depth++;
            $re .= '(?: ';
            next;
        }
        elsif ($pattern =~ m{ \G \)\? }gcxms) {
            $part->[-1]->{optional} = 1;
            $par_depth--;
            $re .= ' )?';
            next;
        }
        elsif ($pattern =~ m{ \G \) }gcxms) {
            $par_depth--;
            $re .= ' )';
            next;
        }

        if ($part->[-1] && substr($pattern, pos($pattern), 1) eq '/') {
            $part->[-1]->{trailing_slash} = 1;
        }
    }

    if ($par_depth != 0) {
        Carp::croak("Parentheses are not balanced in pattern '$pattern'");
    }

    $re = qr/^ $re $/xmsi;

    if ($part && @$part) {
        push @parts, $part;
    }

    $self->{parts}   = [@parts];
    $self->{pattern} = $re;

    return $self;
}

sub _build_match { shift; return Routes::Tiny::Match->new(@_) }

1;
__END__

=head1 NAME

Routes::Tiny::Pattern - Routes pattern

=head1 SYNOPSIS

    my $pattern = Routes::Tiny::Pattern->new(
        pattern  => '/:foo/:bar',
        defaults => {bar => 'index'},
        name     => 'route'
    );

    my $match = $pattern->match('/hello/world');

    my $path = $pattern->build_path('route', foo => 'hello', bar => 'world');

=head1 DESCRIPTION

L<Routes::Tiny::Pattern> is an Object that incapsulates pattern matching and
path building.

=head1 ATTRIBUTES

=head2 C<defaults>

Pass default values for captures.

=head2 C<constraints>

Pass constraints.

=head2 C<name>

Pass route name.

=head1 METHODS

=head2 C<new>

    my $pattern = Routes::Tiny::Pattern->new;

Create new instance of L<Routes::Tiny::Pattern>.

=head2 C<match>

Match pattern agains a path.

=head2 C<build_path>

    $pattern->build_path('name', {foo => 'bar'});

Build path from a given name and params.

=cut
