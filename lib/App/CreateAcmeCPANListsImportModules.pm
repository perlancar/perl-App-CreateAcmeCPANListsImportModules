package App::CreateAcmeCPANListsImportModules;

# DATE
# VERSION

use 5.010001;
use strict;
use warnings;

use Log::Any::IfLOG '$log';
use Perinci::Sub::Util qw(err);

our %SPEC;

sub _url_to_filename {
    my $url = shift;
    $url =~ s![^A-Za-z0-9_.-]+!_!g;
    $url;
}

$SPEC{create_acme_cpanlists_import_modules} = {
    v => 1.1,
    summary => 'Create Acme::CPANLists::Import::* modules',
    description => <<'_',

An `Acme::CPANLists::Import::*` module contains a module list where its entries
(modules) are extracted from a web page. The purpose of creating such module is
to have a POD mentioning the modules, thus adding/improving to the POD "mentions
cloud" on CPAN.

_
    args => {
        modules => {
            schema => ['array*', of=>'hash*'],
            req => 1,
        },
        namespace => {
            schema => 'str*',
            req => 1,
        },
        cache => {
            schema => 'bool',
            default => 1,
        },
        user_agent => {
            summary => 'Set HTTP User-Agent',
            schema => 'str*',
        },
        dist_dir => {
            schema => 'str*',
        },
        exclude_unindexed => {
            summary => 'Consult local CPAN index and exclude module entries '.
                'that are not indexed on CPAN',
            schema => 'bool',
            default => 1,
            description => <<'_',

This requires `App::lcpan` to be installed and a local CPAN index to exist and
be fairly recent.

_
        },
    },
};
sub create_acme_cpanlists_import_modules {
    require Data::Dmp;
    require File::Slurper;
    require HTML::Extract::CPANModules;
    require LWP::UserAgent;
    require POSIX;

    my %args = @_;

    my $ac_modules = $args{modules};
    my $namespace = $args{namespace};
    my $dist_dir = $args{dist_dir} // do { require Cwd; Cwd::get_cwd() };
    my $cache = $args{cache} // 1;

    my $namespace_pm = $namespace; $namespace_pm =~ s!::!/!g;

    my $ua = LWP::UserAgent->new;
    $ua->agent($args{user_agent}) if $args{user_agent};

    my $now = time();

    my %names;
    for my $ac_mod (@$ac_modules) {
        $log->infof("Processing %s ...", $ac_mod->{name});

        return [409, "Duplicate module name '$ac_mod->{name}'"]
            if $names{$ac_mod->{name}}++;

        my @extract_urls;
        if ($ac_mod->{extract_urls}) {
            @extract_urls = @{ $ac_mod->{extract_urls} };
        } else {
            @extract_urls = ($ac_mod->{url});
        }

        my $mods = [];
        my $date;
        for my $url (@extract_urls) {
            my $cache_path = "$dist_dir/devdata/"._url_to_filename($url);
            my @st_cache = stat $cache_path;
            my $content;
            if (!$cache || !@st_cache || $st_cache[9] < $now-30*86400) {
                $log->infof("Retrieving %s ...", $url);
                my $resp = $ua->get($url);
                $resp->is_success
                    or return [500, "Can't get $url: ".$resp->status_line];
                $content = $resp->content;
                File::Slurper::write_text($cache_path, $content);
                $date //= POSIX::strftime("%Y-%m-%d", localtime $now);
            } else {
                $log->infof("Using cache file %s", $cache_path);
                $content = File::Slurper::read_text($cache_path);
                $date //= POSIX::strftime("%Y-%m-%d", localtime($st_cache[9]));
            }

            my $mods0 = HTML::Extract::CPANModules::extract_cpan_modules_from_html(
                html => $content, %{ $ac_mod->{extract_opts} // {}});

            $log->debugf("Extracted module names: %s", $mods0);
            for my $m (@$mods0) {
                push @$mods, $m unless grep { $m eq $_ } @$mods;
            }
        } # for each extract url

        if ($args{exclude_unindexed} && @$mods) {
            require App::lcpan::Call;
            my $lcpan_res = App::lcpan::Call::call_lcpan_script(
                argv => [qw/mods -x --or/, @$mods],
            );
            return err("Can't list modules in lcpan", $lcpan_res)
                unless $lcpan_res->[0] == 200;
            my @excluded_mods;
            my @included_mods;
            for my $mod (@$mods) {
                if (grep { $mod eq $_ } @{$lcpan_res->[2]}) {
                    push @included_mods, $mod;
                } else {
                    push @excluded_mods, $mod;
                }
            }
            $mods = \@included_mods;

            if (@excluded_mods) {
                $log->debugf("Excluded module names (not indexed on ".
                                 "local CPAN mirror): %s", \@excluded_mods);
            }
        }

        push @$mods, @{$ac_mod->{add_modules}} if $ac_mod->{add_modules};

        return [412, "No module names found for $ac_mod->{name}"] unless @$mods;

        my $ac_module_path = "$dist_dir/lib/$namespace_pm/$ac_mod->{name}.pm";

        my $mod_list = {
            summary => $ac_mod->{summary},
            description => "This list is generated by extracting module names mentioned in [$ac_mod->{url}] (retrieved on $date). Visit the URL for the full contents.",
            entries => [map {+{module=>$_}} @$mods],
        };

        my @pm_content = (
            "package $namespace\::$ac_mod->{name};\n",
            "\n",
            "# DATE\n",
            "# VERSION\n",
            "\n",
            "our \@Module_Lists = (", Data::Dmp::dmp($mod_list), ");\n",
            "\n",
            "1;\n",
            "# ABSTRACT: $ac_mod->{summary}\n",
            "\n",
            "=head1 DESCRIPTION\n",
            "\n",
            "This module is generated by extracting module names mentioned in L<$ac_mod->{url}> (retrieved on $date). Visit the URL for the full contents.\n",
            ($ac_mod->{note} ? "\n$ac_mod->{note}\n\n" : ""),
            "\n",
        );

        $log->infof("Writing module %s ...", $ac_module_path);
        File::Slurper::write_text($ac_module_path, join("", @pm_content));
    }

    [200];
}

1;
# ABSTRACT:

=head1 SEE ALSO

L<Acme::CPANLists>

Some C<Acme::CPANLists::Import::*> modules which utilize this during building:
L<Acme::CPANLists::Import::NEILB>, L<Acme::CPANLists::Import::SHARYANTO>,
L<Acme::CPANLists::Import::RSAVAGE>, L<Acme::CPANLists::Import>, and so on.

L<App::lcpan>, L<lcpan>, especially the B<related-mods> subcommand.

=cut
