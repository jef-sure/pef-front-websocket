use ExtUtils::MakeMaker;
WriteMakefile(
	NAME             => "PEF::Front::WebSocket",
	AUTHOR           => "Anton Petrusevich",
	VERSION          => "0.03",
	LICENSE          => "artistic_2",
	INSTALLDIRS      => 'site',
	MIN_PERL_VERSION => "5.014000",
	META_MERGE       => {
		"meta-spec" => {version => 2},
		resources   => {
			bugtracker => {web => 'https://github.com/jef-sure/pef-front-websocket/issues'},
			repository => {
				type => 'git',
				url  => 'https://github.com/jef-sure/pef-front-websocket.git',
				web  => 'https://github.com/jef-sure/pef-front-websocket',
			},
		},
	},
	PREREQ_PM => {
		'AnyEvent'            => 0,
		'AnyEvent::Handle'    => 0,
		'Coro'                => 0,
		'Coro::AnyEvent'      => 0,
		'Data::Dumper'        => 0,
		'Errno'               => 0,
		'PEF::Front'          => 0.09,
		'Compress::Raw::Zlib' => 0,
		'Protocol::WebSocket' => 0.20,
	},
	TEST_REQUIRES => {
		'Test::More'            => 0,
		'Data::Structure::Util' => 0,
		'Clone'                 => 0
	},
	test => {TESTS => "t/*.t"},
	dist => {
		DIST_DEFAULT => 'all tardist',
		COMPRESS     => 'gzip -vf',
		SUFFIX       => '.gz',
	},
	clean     => {FILES => '*~',},
	realclean => {FILES => '*~',},
);
