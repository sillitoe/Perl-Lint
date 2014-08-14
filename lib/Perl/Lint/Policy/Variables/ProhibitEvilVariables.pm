package Perl::Lint::Policy::Variables::ProhibitEvilVariables;
use strict;
use warnings;
use Carp ();
use Regexp::Parser;
use Perl::Lint::Constants::Type;
use parent "Perl::Lint::Policy";

use constant {
    DESC => 'The names of or patterns for variables to forbid.',
    EXPL => 'Find an alternative variable',
};

use constant VAR_TOKENS => {
    &VAR              => 1,
    &CODE_VAR         => 1,
    &ARRAY_VAR        => 1,
    &HASH_VAR         => 1,

    &GLOBAL_VAR       => 1,
    &GLOBAL_ARRAY_VAR => 1,
    &GLOBAL_HASH_VAR  => 1,

    &LOCAL_VAR        => 1,
    &LOCAL_ARRAY_VAR  => 1,
    &LOCAL_HASH_VAR   => 1,

    &SPECIFIC_VALUE   => 1,
};

use constant DEREFERENCE_TOKENS => {
    &SCALAR_DEREFERENCE => 1,
    &HASH_DEREFERENCE   => 1,
};

sub evaluate {
    my ($class, $file, $tokens, $src, $args) = @_;

    my $variable_specifications = $args->{prohibit_evil_variables}->{variables};
    my $variable_specification_files = $args->{prohibit_evil_variables}->{variables_file};

    my $VARIABLE_NAME_REGEX = qr< [\$\@%] \S+ >xms;
    my $REGULAR_EXPRESSION_REGEX = qr< [/] ( [^/]+ ) [/] >xms;
    my @DESCRIPTION_REGEXES = (
        qr< [{] ( [^}]+ ) [}] >xms,
        qr{  <  ( [^>]+ )  >  }xms,
        qr{ [[] ( [^]]+ ) []] }xms,
        qr{ [(] ( [^)]+ ) [)] }xms,
    );
    my $DESCRIPTION_REGEX = qr< @{[join '|', @DESCRIPTION_REGEXES]} >xms;

    my @evil_variables;
    my @evil_variables_regex;

    if ($variable_specifications) {
        my $VARIABLES_REGEX = qr<
            \A
            \s*
            (?:
                    ( $VARIABLE_NAME_REGEX )
                |   $REGULAR_EXPRESSION_REGEX
            )
            (?: \s* $DESCRIPTION_REGEX )?
            \s*
        >xms;

        while (my ($variable, $regex_string, @descrs) = $variable_specifications =~ m/ $VARIABLES_REGEX /xms) {
            substr $variable_specifications, 0, $+[0], '';

            if ($variable) {
                push @evil_variables, $variable;
            }
            else {
                push @evil_variables_regex, $regex_string;
            }
        }
    }

    if ($variable_specification_files) {
        my $VARIABLES_FILE_LINE_REGEX = qr<
            \A
            \s*
            (?:
                    ( $VARIABLE_NAME_REGEX )
                |   $REGULAR_EXPRESSION_REGEX
            )
            \s*
            ( \S (?: .* \S )? )?
            \s*
            \z
        >xms;

        open my $fh, '<', $variable_specification_files or die "Cannot open file: $!";
        while (my $line = <$fh>) {
            $line =~ s< [#] .* \z ><>xms;
            $line =~ s< \s+ \z ><>xms;
            $line =~ s< \A \s+ ><>xms;

            next if not $line;

            if (my ($variable, $regex_string, $description) =
                $line =~ m< $VARIABLES_FILE_LINE_REGEX >xms) {

                if ($variable) {
                    push @evil_variables, $variable;
                }
                else {
                    push @evil_variables_regex, $regex_string;
                }
            }
        }
    }

    my %used_var_with_line_num;
    for (my $i = 0, my $token_type, my $token_data; my $token = $tokens->[$i]; $i++) {
        $token_type = $token->{type};
        $token_data = $token->{data};

        if (VAR_TOKENS->{$token_type} || DEREFERENCE_TOKENS->{$token_type}) {
            my $var  = $token_data;
            my $line = $token->{line};

            my $opener;
            my $closer;
            if (DEREFERENCE_TOKENS->{$token_type}) { # XXX workaround
                $opener = LEFT_BRACE;
                $closer = RIGHT_BRACE;
            }
            elsif ($token_type == SPECIFIC_VALUE && $token_data eq '$^') { # XXX ad hoc
                $token = $tokens->[++$i];
                $var .= $token->{data};
                $used_var_with_line_num{$var} = $line;
                next;
            }
            else {
                $token = $tokens->[++$i];
                $token_type = $token->{type};

                if ($token_type == LEFT_BRACE) {
                    $opener = LEFT_BRACE;
                    $closer = RIGHT_BRACE;
                }
                elsif ($token_type == LEFT_BRACKET) {
                    $opener = LEFT_BRACKET;
                    $closer = RIGHT_BRACKET;
                }
                else {
                    $used_var_with_line_num{$var} = $line;
                    next;
                }

                $var .= $token->{data}; # data of opener
            }

            my $left_bracket_num = 1;
            for ($i++; $token = $tokens->[$i]; $i++) {
                $token_type = $token->{type};

                $var .= $token->{data};

                if ($token_type == $opener) {
                    $left_bracket_num++;
                }
                elsif ($token_type == $closer) {
                    last if --$left_bracket_num <= 0;
                }
            }
            $used_var_with_line_num{$var} = $line;
        }
    }

    my @violations;
    for my $evil_var (@evil_variables) {
        (my $alt_evil_var = $evil_var) =~ s/\A[\%\@]/\$/;

        my $line;
        if (
            $line = $used_var_with_line_num{$evil_var} or
            ($alt_evil_var and $line = $used_var_with_line_num{$alt_evil_var})
        ) {
            push @violations, {
                filename => $file,
                line     => $line,
                description => DESC,
                explanation => EXPL,
                policy => __PACKAGE__,
            };
        }
    }

    my $regexp_parser = Regexp::Parser->new;
    for my $regex (@evil_variables_regex) {
        if (! $regexp_parser->parse($regex)) {
            Carp::croak "invalid regular expression: /$regex/";
        }

        for my $used_var (keys %used_var_with_line_num) {
            if ($used_var =~ /$regex/) {
                push @violations, {
                    filename => $file,
                    line     => $used_var_with_line_num{$used_var},
                    description => DESC,
                    explanation => EXPL,
                    policy => __PACKAGE__,
                };
            }
        }
    }

    return \@violations;
}

1;

