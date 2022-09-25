#!/bin/bash

# A script to execute a main class of a Maven artifact
# which is available locally or from Maven Central.
#
# Works using the maven-dependency-plugin to stash the artifact
# and its deps to a temporary location, then invokes java.
#
# It would be more awesome to enhance the exec-maven-plugin to support
# running something with a classpath built from the local Maven repository
# cache. Then you would get all the features of exec-maven-plugin.
# But this script works in a pinch for simple cases.

# Define some useful functions.

notice() { test $quiet || echo "$@"; }
info() { test $verbose && echo "[INFO] $@"; }
err() { echo "$@" 1>&2; }
die() { err "$@"; exit 1; }

check() {
	for tool in $@
	do
		which "$tool" >/dev/null ||
			die "The '$tool' utility is required but not found"
	done
}

doLink() {
	case "$links" in
		soft)
			# Use symlinks.
			check ln cp
			(test $verbose && set -x; ln -s "$1" "$2") ||
			(test $verbose && set -x; cp "$1" "$2") ||
				die "Cannot copy '$1' into jgo workspace '$2'"
			;;
		none)
			# Do not use links.
			check cp
			(test $verbose && set -x; cp "$1" "$2") ||
				die "Cannot copy '$1' into jgo workspace '$2'"
			;;
		*)
			# Use hard links (the default).
			check ln cp
			(test $verbose && set -x; ln "$1" "$2") ||
			(test $verbose && set -x; cp "$1" "$2") ||
				die "Cannot copy '$1' into jgo workspace '$2'"
			;;
	esac
}

isWindows() {
	case "$(uname)" in
		CYGWIN*)
			echo "cygwin"
			;;
		MINGW*)
			echo "mingw"
			;;
		*)
			;;
	esac
}

goodPath() {
	# NB: Non-POSIX Windows programs, including mvn and java,
	# do not understand the POSIX-compliant '/' prefix. They need
	# absolute paths to begin with a drive letter (e.g., 'C:').
	if [ "$(isWindows)" ]
	then
		echo "$(cygpath -aw "$(dirname "$1")")\\$(basename "$1")"
	else
		echo "$1"
	fi
}

m2Path() {
	test "$M2_REPO" && echo "$M2_REPO" || echo "$HOME/.m2"
}

trim() {
	check sed
	echo "$*" | sed 's/^ *//' | sed 's/ *$//'
}

expand() {
	local expanded="$@"
	for shortcut in "${shortcuts[@]}"
	do
		key=$(trim "${shortcut%=*}")
		val=$(trim "${shortcut#*=}")
		case "$expanded" in
			$key*)
				expanded="$val${expanded#$key}"
				;;
		esac
	done
	echo "$expanded"
}

launchJava() {
	check java
	(
		goodCP=$(goodPath "$workspace/*")
		test $verbose && set -x
		java -cp "$goodCP" "${jvm_args[@]}" "$mainClass" "${app_args[@]}"
	)
}

# Parse configuration file.

configFile="$HOME/.jgorc"
cacheDir="$HOME/.jgo"
m2Repo="$(m2Path)/repository"
repositories=()
shortcuts=()

test -f "$configFile" &&
while read line
do
	case "$line" in
		'#'*)
			# skip comment
			;;
		\[*\])
			ltrim=${line:1}
			section=${ltrim%?}
			;;
		*=*)
			case "$section" in
				repositories)
					repositories+=("$line")
					;;
				settings)
					key=$(trim "${line%=*}")
					val=$(trim "${line#*=}")
					case "$key" in
						cacheDir) cacheDir="$val";;
						m2Repo) m2Repo="$val";;
						links) links="$val";;
					esac
					;;
				shortcuts)
					shortcuts+=("$line")
					;;
				*)
					;;
			esac
			;;
	esac
done <"$configFile"

# Parse arguments.

jvm_args=()
app_args=()
while test $# -gt 0
do
	if [ "$endpoint" ]
	then
		# Argument to the main class.
		app_args+=("$1")
	else
		# Argument to the JVM, or jgo itself.
		case "$1" in
			-m)
				manageDeps=1
				;;
			-v)
				verbose=1
				;;
			-vv)
				verbose=2
				;;
			-u)
				updateCache=1
				;;
			-U)
				updateMaven=1
				updateCache=1
				;;
                        -q)
				quiet=1
				;;
			-*)
				jvm_args+=("$1")
				;;
			*)
				endpoint="$1"
				;;
		esac
	fi
	shift
done

# Parse the endpoint.

endpoint=$(expand "$endpoint")
test "$endpoint" || endpoint=usage

eRemain=$endpoint
while test "$eRemain"
do
	# Process the artifact string before the plus.
	artifact=${eRemain%%+*}
	let flen=${#artifact}+1
	eRemain=${eRemain:$flen}

	artifact=$(expand "$artifact")

	c=""
	m=""
	case "$artifact" in
		*:*:*:*:*:*) # G:A:V:C:mainClass
			die "Too many elements in artifact '$artifact'"
			;;
		*:*:*:*:*) # G:A:V:C:mainClass
			g=${artifact%%:*}; remain=${artifact#*:}
			a=${remain%%:*}; remain=${remain#*:}
			v=${remain%%:*}; remain=${remain#*:}
			c=${remain%%:*}
			m=${remain#*:}
			;;
		*:*:*:*) # G:A:V:mainClass
			g=${artifact%%:*}; remain=${artifact#*:}
			a=${remain%%:*}; remain=${remain#*:}
			v=${remain%%:*}
			m=${remain#*:}
			;;
		*:*:*) # G:A:mainClass or G:A:V
			g=${artifact%%:*}; remain=${artifact#*:}
			a=${remain%%:*}; remain=${remain#*:}
			case "$remain" in
				[0-9a-f]*|RELEASE|LATEST|MANAGED)
					v="$remain"
					;;
				*)
					v="RELEASE"
					m="$remain"
					;;
			esac
			;;
		*:*) # G:A
			g=${artifact%%:*}
			a=${artifact#*:}
			v="RELEASE"
			;;
		*)
			echo "Usage: jgo [-v] [-u] [-U] [-m] [-q] <jvm-args> <endpoint> <main-args>"
			echo
			echo "  -v          : verbose mode flag"
			echo "  -u          : update/regenerate cached environment"
			echo "  -U          : force update from remote Maven repositories (implies -u)"
			echo "  -m          : use endpoints for dependency management (see README)"
			echo "  -q          : quiet mode flag to suppress regular output"
			echo "  <jvm-args>  : any list of arguments to the JVM"
			echo "  <endpoint>  : the artifact(s) + main class to execute"
			echo "  <main-args> : any list of arguments to the main class"
			echo
			echo "The endpoint should have one of the following formats:"
			echo
			echo "- groupId:artifactId"
			echo "- groupId:artifactId:version"
			echo "- groupId:artifactId:mainClass"
			echo "- groupId:artifactId:version:mainClass"
			echo "- groupId:artifactId:version:classifier:mainClass"
			echo
			echo "If version is omitted, then RELEASE is used."
			echo "If version is MANAGED, then the <version> tag is omitted in"
			echo "the dependency xml and must be managed by another endpoint."
			echo "If mainClass is omitted, it is auto-detected."
			echo "You can also write part of a class beginning with an @ sign,"
			echo "and it will be auto-completed."
			echo
			echo "Multiple artifacts can be concatenated with pluses,"
			echo "and all of them will be included on the classpath."
			echo "However, you should not specify multiple main classes."
			exit 1
			;;
	esac
	info "Artifact:"
	info "- groupId    = $g"
	info "- artifactId = $a"
	info "- version    = $v"
	test "$c" && info "- classifier = $c" || info "- classifier = <none>"
	test "$m" && mainClass="$m"

	deps="$deps<dependency><groupId>$g</groupId><artifactId>$a</artifactId>"
	test "$v" != "MANAGED" && deps="$deps<version>$v</version>"
	test "$c" && deps="$deps<classifier>$c</classifier>"
	deps="$deps</dependency>"

	if [ "$manageDeps" ] && [ "$v" != "MANAGED" ]
	then
		depMgmt="$depMgmt<dependency><groupId>$g</groupId><artifactId>$a</artifactId><version>$v</version>"
		test "$c" && depMgmt="$depMgmt<classifier>$c</classifier>"
		depMgmt="$depMgmt<type>pom</type><scope>import</scope></dependency>"
	fi
done

# Create a workspace in the jgo cache directory

check sed rm mkdir
workspace="$cacheDir/$(echo "$endpoint" | sed 's/[:+]/\//g' | sed 's/[^0-9a-zA-Z/\.-]/_/g')"

test $updateCache && rm -rf "$workspace"
mkdir -p "$workspace"
info "Workspace = $workspace"

if [ -f "$workspace/mainClass" ]
then
	# Workspace is already populated; just use it
	check cat
	mainClass=$(cat "$workspace/mainClass")
	launchJava
	exit $?
fi

notice 'First time start-up may be slow. Downloaded dependencies will be cached for shorter start-up times in subsequent executions.'

# Synthesize a dummy Maven project.

for repository in "${repositories[@]}"
do
	key=$(trim "${repository%=*}")
	val=$(trim "${repository#*=}")
	repos="$repos<repository><id>$key</id><url>$val</url></repository>"
done

check cat
tmpPOM="$workspace/pom.xml"
cat >"$tmpPOM" <<EOL
<project>
	<modelVersion>4.0.0</modelVersion>
	<groupId>$g-BOOTSTRAPPER</groupId>
	<artifactId>$a-BOOTSTRAPPER</artifactId>
	<version>0</version>
	<dependencyManagement>
		<dependencies>$depMgmt</dependencies>
	</dependencyManagement>
	<dependencies>$deps</dependencies>
	<repositories>$repos</repositories>
</project>
EOL

check mvn
test $updateMaven && mvnArgs=-U
test "$verbose" = "2" && mvnArgs=-X
goodPOM=$(goodPath "$tmpPOM")
buildLog=$(test $verbose && set -x; mvn -B $mvnArgs -f "$goodPOM" dependency:resolve 2>&1)
if [ $? -ne 0 ]
then
	err "Failed to bootstrap the artifact."
	err
	err "Possible solutions:"
	err "* Double check the endpoint for correctness (https://search.maven.org/)."
	err "* Add needed repositories to ~/.jgorc [repositories] block (see README)."
	err "* Try with an explicit version number (release metadata might be wrong)."
	err
	if [ "$verbose" ]
	then
		err "Here is the Maven log:"
		err "$buildLog"
	else
		err "Rerun with the -v flag to see the Maven log."
	fi
	exit 2
fi

# Build a workspace of symlinked artifacts.

check grep sed
echo "$buildLog" | grep ':\(compile\|runtime\)' | sed 's/\[INFO\] *//' |
while read gav
do
	case "$gav" in
		*:*:*:*:*:*) # G:A:P:C:V:S
			g=${gav%%:*}; remain=${gav#*:}
			a=${remain%%:*}; remain=${remain#*:}
			p=${remain%%:*}; remain=${remain#*:}
			c=${remain%%:*}; remain=${remain#*:}
			v=${remain%%:*}
			s=${remain#*:}
			;;
		*:*:*:*:*) # G:A:P:V:S
			g=${gav%%:*}; remain=${gav#*:}
			a=${remain%%:*}; remain=${remain#*:}
			p=${remain%%:*}; remain=${remain#*:}
			c=""
			v=${remain%%:*}
			s=${remain#*:}
			;;
	esac
	# NB: test-jar packaging means jar packaging + tests classifier.
	test "$p" = test-jar && p=jar && c=tests
	g=$(echo "$g" | sed 's/\./\//g')
	test "$c" && artName="$a-$v-$c" || artName="$a-$v"
	doLink "$m2Repo/$g/$a/$v/$artName.$p" "$workspace"
done

# Massage the main class as needed.

if [ -z "$mainClass" ]
then
	# Infer the main class from the JAR manifest.
	check unzip grep head sed
	jarPathPrefix="$workspace/$a"
	test "$c" && jarPathPrefix="$jarPathPrefix-$c"
	mainClass=$((test $verbose && set -x;
		unzip -p "$jarPathPrefix"-[0-9a-f]*.jar META-INF/MANIFEST.MF 2>/dev/null) |
		grep Main-Class | head -n1 | sed 's/^Main-Class: *\([a-zA-Z0-9_\.]*\).*/\1/')
	info "Inferred main class: $mainClass"
fi
test "$mainClass" || die "No main class given, and none found."

if [ "z${mainClass:0:1}" = 'z@' ]
then
	# Autocomplete the main class by scanning the JARs.
	check jar grep sed
	mainPath=$(echo "${mainClass:1}" | sed 's/\//./g')
	allClasses=$((test $verbose && set -x;
		for jar in "$workspace/"*.jar; do jar tf "$jar"; done) |
		grep '\.class$' | sed 's/\//./g')
	completedClass=$(echo "$allClasses" |
		grep "$mainPath\.class$" | head -n1 | sed 's/\.class$//')
	test "$completedClass" || completedClass=$(echo "$allClasses" |
		grep "$mainPath.*\.class$" | head -n1 | sed 's/\.class$//')
	test "$completedClass" ||
		die "No autocompletions found for '$mainClass'"
	mainClass=$completedClass
	info "Autocompleted main class: $mainClass"
fi
echo "$mainClass" >"$workspace/mainClass"

# Launch it!

launchJava
