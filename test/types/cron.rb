# Test cron job creation, modification, and destruction

if __FILE__ == $0
    $:.unshift '..'
    $:.unshift '../../lib'
    $puppetbase = "../../../../language/trunk"
end

require 'puppettest'
require 'puppet'
require 'test/unit'
require 'facter'


# Here we just want to unit-test our cron type, to verify that 
#class TestCronType < Test::Unit::TestCase
#	include TestPuppet
#
#
#end

class TestCron < Test::Unit::TestCase
	include TestPuppet
    def setup
        super
        # retrieve the user name
        id = %x{id}.chomp
        if id =~ /uid=\d+\(([^\)]+)\)/
            @me = $1
        else
            puts id
        end
        unless defined? @me
            raise "Could not retrieve user name; 'id' did not work"
        end

        # god i'm lazy
        @crontype = Puppet.type(:cron)
        @oldfiletype = @crontype.filetype
        @fakefiletype = Puppet::FileType.filetype(:ram)
        @crontype.filetype = @fakefiletype
    end

    def teardown
        @crontype.filetype = @oldfiletype
        super
    end

    # Back up the user's existing cron tab if they have one.
    def cronback
        tab = nil
        assert_nothing_raised {
            tab = Puppet.type(:cron).filetype.read(@me)
        }

        if $? == 0
            @currenttab = tab
        else
            @currenttab = nil
        end
    end

    # Restore the cron tab to its original form.
    def cronrestore
        assert_nothing_raised {
            if @currenttab
                @crontype.filetype.new(@me).write(@currenttab)
            else
                @crontype.filetype.new(@me).remove
            end
        }
    end

    # Create a cron job with all fields filled in.
    def mkcron(name)
        cron = nil
        assert_nothing_raised {
            cron = @crontype.create(
                :command => "date > %s/crontest%s" % [tmpdir(), name],
                :name => name,
                :user => @me,
                :minute => rand(59),
                :month => "1",
                :monthday => "1",
                :hour => "1"
            )
        }

        return cron
    end

    # Run the cron through its paces -- install it then remove it.
    def cyclecron(cron)
        name = cron.name
        comp = newcomp(name, cron)

        assert_events([:cron_created], comp)
        cron.retrieve

        assert(cron.insync?)

        assert_events([], comp)

        cron[:ensure] = :absent

        assert_events([:cron_removed], comp)

        cron.retrieve

        assert(cron.insync?)
        assert_events([], comp)
    end

    # A simple test to see if we can load the cron from disk.
    def test_load
        assert_nothing_raised {
            @crontype.retrieve(@me)
        }
    end

    # Test that a cron job turns out as expected, by creating one and generating
    # it directly
    def test_simple_to_cron
        cron = nil
        # make the cron
        name = "yaytest"
        assert_nothing_raised {
            cron = @crontype.create(
                :name => name,
                :command => "date > /dev/null",
                :user => @me
            )
        }
        str = nil
        # generate the text
        assert_nothing_raised {
            str = cron.to_record
        }

        assert_equal(str, "# Puppet Name: #{name}\n* * * * * date > /dev/null",
            "Cron did not generate correctly")
    end

    # Test that changing any field results in the cron tab being rewritten.
    # it directly
    def test_any_field_changes
        cron = nil
        # make the cron
        name = "yaytest"
        assert_nothing_raised {
            cron = @crontype.create(
                :name => name,
                :command => "date > /dev/null",
                :month => "May",
                :user => @me
            )
        }
        assert(cron, "Cron did not get created")
        comp = newcomp(cron)
        assert_events([:cron_created], comp)

        assert_nothing_raised {
            cron[:month] = "June"
        }

        cron.retrieve

        assert_events([:cron_changed], comp)
    end

    # Test that a cron job with spaces at the end doesn't get rewritten
    def test_trailingspaces
        cron = nil
        # make the cron
        name = "yaytest"
        assert_nothing_raised {
            cron = @crontype.create(
                :name => name,
                :command => "date > /dev/null ",
                :month => "May",
                :user => @me
            )
        }
        comp = newcomp(cron)

        assert_events([:cron_created], comp, "did not create cron job")
        cron.retrieve
        assert_events([], comp, "cron job got rewritten")
    end
    
    # Test that comments are correctly retained
    def test_retain_comments
        str = "# this is a comment\n#and another comment\n"
        user = "fakeuser"
        assert_nothing_raised {
            @crontype.parse(user, str)
        }

        assert_nothing_raised {
            newstr = @crontype.tab(user)
            assert(newstr.include?(str), "Comments were lost")
        }
    end

    # Test that a specified cron job will be matched against an existing job
    # with no name, as long as all fields match
    def test_matchcron
        str = "0,30 * * * * date\n"

        assert_nothing_raised {
            @crontype.parse(@me, str)
        }

        assert_nothing_raised {
            cron = @crontype.create(
                :name => "yaycron",
                :minute => [0, 30],
                :command => "date",
                :user => @me
            )
        }

        modstr = "# Puppet Name: yaycron\n%s" % str

        assert_nothing_raised {
            newstr = @crontype.tab(@me)
            assert(newstr.include?(modstr),
                "Cron was not correctly matched")
        }
    end

    # Test adding a cron when there is currently no file.
    def test_mkcronwithnotab
        tab = @fakefiletype.new(@me)
        tab.remove

        cron = mkcron("testwithnotab")
        cyclecron(cron)
    end

    def test_mkcronwithtab
        tab = @fakefiletype.new(@me)
        tab.remove
        tab.write(
"1 1 1 1 * date > %s/crontesting\n" % tstdir()
        )

        cron = mkcron("testwithtab")
        cyclecron(cron)
    end

    def test_makeandretrievecron
        tab = @fakefiletype.new(@me)
        tab.remove

        %w{storeandretrieve a-name another-name more_naming SomeName}.each do |name|
            cron = mkcron(name)
            comp = newcomp(name, cron)
            trans = assert_events([:cron_created], comp, name)
            
            cron = nil

            Puppet.type(:cron).retrieve(@me)

            assert(cron = Puppet.type(:cron)[name], "Could not retrieve named cron")
            assert_instance_of(Puppet.type(:cron), cron)
        end
    end

    # Do input validation testing on all of the parameters.
    def test_arguments
        values = {
            :monthday => {
                :valid => [ 1, 13, "1" ],
                :invalid => [ -1, 0, 32 ]
            },
            :weekday => {
                :valid => [ 0, 3, 6, "1", "tue", "wed",
                    "Wed", "MOnday", "SaTurday" ],
                :invalid => [ -1, 7, "13", "tues", "teusday", "thurs" ]
            },
            :hour => {
                :valid => [ 0, 21, 23 ],
                :invalid => [ -1, 24 ]
            },
            :minute => {
                :valid => [ 0, 34, 59 ],
                :invalid => [ -1, 60 ]
            },
            :month => {
                :valid => [ 1, 11, 12, "mar", "March", "apr", "October", "DeCeMbEr" ],
                :invalid => [ -1, 0, 13, "marc", "sept" ]
            }
        }

        cron = mkcron("valtesting")
        values.each { |param, hash|
            # We have to test the valid ones first, because otherwise the
            # state will fail to create at all.
            [:valid, :invalid].each { |type|
                hash[type].each { |value|
                    case type
                    when :valid:
                        assert_nothing_raised {
                            cron[param] = value
                        }

                        if value.is_a?(Integer)
                            assert_equal(value.to_s, cron.should(param),
                                "Cron value was not set correctly")
                        end
                    when :invalid:
                        assert_raise(Puppet::Error, "%s is incorrectly a valid %s" %
                            [value, param]) {
                            cron[param] = value
                        }
                    end

                    if value.is_a?(Integer)
                        value = value.to_s
                        redo
                    end
                }
            }
        }
    end

    # Test that we can read and write cron tabs
    def test_crontab
        Puppet.type(:cron).filetype = Puppet.type(:cron).defaulttype
        type = nil
        unless type = Puppet.type(:cron).filetype
            $stderr.puts "No crontab type; skipping test"
        end

        obj = nil
        assert_nothing_raised {
            obj = type.new(Process.uid)
        }

        txt = nil
        assert_nothing_raised {
            txt = obj.read
        }

        assert_nothing_raised {
            obj.write(txt)
        }
    end

    # Verify that comma-separated numbers are not resulting in rewrites
    def test_norewrite
        cron = nil
        assert_nothing_raised {
            cron = Puppet.type(:cron).create(
                :command => "/bin/date > /dev/null",
                :minute => [0, 30],
                :name => "crontest"
            )
        }

        assert_events([:cron_created], cron)
        cron.retrieve
        assert_events([], cron)
    end

    def test_fieldremoval
        cron = nil
        assert_nothing_raised {
            cron = Puppet.type(:cron).create(
                :command => "/bin/date > /dev/null",
                :minute => [0, 30],
                :name => "crontest"
            )
        }

        assert_events([:cron_created], cron)

        cron[:minute] = :absent
        assert_events([:cron_changed], cron)
        assert_nothing_raised {
            cron.retrieve
        }
        assert_equal(:absent, cron.is(:minute))
    end

    def test_listing
        @crontype.filetype = @oldfiletype

        crons = []
        assert_nothing_raised {
            Puppet::Type.type(:cron).list.each do |cron|
                crons << cron
            end
        }

        crons.each do |cron|
            assert(cron, "Did not receive a real cron object")
            assert_instance_of(String, cron[:user],
                "Cron user is not a string")
        end
    end

    def verify_failonnouser
        assert_raise(Puppet::Error) do
            @crontype.retrieve("nosuchuser")
        end
    end

    def test_names
        cron = mkcron("nametest")

        ["bad name", "bad.name"].each do |name|
            assert_raise(ArgumentError) do
                cron[:name] = name
            end
        end

        ["good-name", "good-name", "AGoodName"].each do |name|
            assert_nothing_raised do
                cron[:name] = name
            end
        end
    end

    # Make sure we don't puke on env settings
    def test_envsettings
        cron = mkcron("envtst")

        assert_apply(cron)

        obj = Puppet::Type::Cron.cronobj(@me)

        assert(obj)

        text = obj.read

        text = "SHELL = /path/to/some/thing\n" + text

        obj.write(text)

        assert_nothing_raised {
            cron.retrieve
        }

        cron[:command] = "/some/other/command"

        assert_apply(cron)

        assert(obj.read =~ /SHELL/, "lost env setting")

        env1 = "TEST = /bin/true"
        env2 = "YAY = fooness"
        assert_nothing_raised {
            cron[:environment] = [env1, env2]
        }

        assert_apply(cron)
        cron.retrieve

        vals = cron.is(:environment)
        assert(vals, "Did not get environment settings")
        assert(vals != :absent, "Env is incorrectly absent")
        assert_instance_of(Array, vals)

        assert(vals.include?(env1), "Missing first env setting")
        assert(vals.include?(env2), "Missing second env setting")

    end

    def test_divisionnumbers
        cron = mkcron("divtest")
        cron[:minute] = "*/5"

        assert_apply(cron)

        cron.retrieve

        assert_equal(["*/5"], cron.is(:minute))
    end

    def test_ranges
        cron = mkcron("rangetest")
        cron[:minute] = "2-4"

        assert_apply(cron)

        cron.retrieve

        assert_equal(["2-4"], cron.is(:minute))
    end
end

# $Id$
