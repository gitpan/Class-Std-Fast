use lib '../lib';
use Benchmark;
my @list;

package MyBenchTestFast;
use Class::Std::Fast;

my %one_of :ATTR(:name<one> :default<()>);
my %two_of :ATTR(:name<two> :default<()>);
my %three_of :ATTR(:name<three> :default<()>);
my %four_of :ATTR(:name<four> :default<()>);

Class::Std::initialize;

1;

package MyBenchTest;
use Class::Std;

my %one_of :ATTR(:name<one> :default<()>);
my %two_of :ATTR(:name<two> :default<()>);
my %three_of :ATTR(:name<three> :default<()>);
my %four_of :ATTR(:name<four> :default<()>);

Class::Std::initialize;
1;

package MyBenchTestFast2;
use Class::Std::Fast qw(2);

my %one_of :ATTR(:name<one>);
my %two_of :ATTR(:name<two>);
my %three_of :ATTR(:name<three>);
my %four_of :ATTR(:name<four>);
Class::Std::initialize;
1;


package main;

for my $class ('MyBenchTestFast2', 'MyBenchTestFast', 'MyBenchTest') {
    print $class, "\n";
     
    timethis 50000 , sub {
        push @list,  $class->new();
        $list[-1]->set_one($class->new());
        $list[-1]->get_one()->set_two($class->new());
        $list[-1]->get_one();
    };
    timethis 1, sub { undef @list };
}


