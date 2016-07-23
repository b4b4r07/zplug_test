__zplug::utils::git::clone()
{
    local    repo="${1:?}"
    local    depth_option url_format
    local -i ret=1
    local -A tags

    # A validation of ZPLUG_PROTOCOL
    # - HTTPS (recommended)
    # - SSH
    if [[ ! $ZPLUG_PROTOCOL =~ ^(HTTPS|https|SSH|ssh)$ ]]; then
        __zplug::io::print::f \
            --die \
            --zplug \
            --error \
            "ZPLUG_PROTOCOL is an invalid protocol.\n"
        return 1
    fi

    __zplug::core::tags::parse "$repo" || return 1
    tags=( "${reply[@]}" )

    if [[ $tags[depth] == 0 ]]; then
        depth_option=""
    else
        depth_option="--depth=$tags[depth]"
    fi

    # Assemble a URL for cloning from its handler
    if __zplug::core::sources::is_handler_defined "get_url" "$tags[from]"; then
        __zplug::core::sources::use_handler \
            "get_url" \
            "$tags[from]" \
            "$repo" \
            | read url_format

        if [[ -z $url_format ]]; then
            __zplug::io::print::f \
                --die \
                --zplug \
                --error \
                "$repo is an invalid 'user/repo' format.\n"
            return 1
        fi

        GIT_TERMINAL_PROMPT=0 git clone \
            ${=depth_option} \
            --recursive \
            --quiet \
            "$url_format" "$tags[dir]" \
            2>&1 | __zplug::io::report::save
    fi

    # The revison (hash/branch/tag) lock
    __zplug::utils::git::checkout "$repo"

    return $status
}

__zplug::utils::git::checkout()
{
    local    repo="${1:?}"
    local -a do_not_checkout
    local -A tags

    do_not_checkout=( "gh-r" )
    tags[at]="$(__zplug::core::core::run_interfaces 'at' "$repo")"
    tags[dir]="$(__zplug::core::core::run_interfaces 'dir' "$repo")"
    tags[from]="$(__zplug::core::core::run_interfaces 'from' "$repo")"

    if (( $do_not_checkout[(I)$tags[from]] )); then
        return 0
    fi

    # Try not to be affected by directory changes
    # by running in subshell
    (
    __zplug::utils::shell::cd \
        "$tags[dir]" \
        "$tags[dir]:h"
    if (( $status != 0 )); then
        __zplug::io::print::f \
            --die \
            --zplug \
            --error \
            "no such directory '$tags[dir]' ($repo)\n"
        return 1
    fi

    git checkout -q "$tags[at]" \
        2>&1 | __zplug::io::report::save
    # Get pipestatus
    __zplug::utils::shell::pipestatus
    if (( $status != 0 )); then
        __zplug::io::print::f \
            --die \
            --zplug \
            --error \
            "pathspec '$tags[at]' (at tag) did not match ($repo)\n"
    fi
    )
}

__zplug::utils::git::merge()
{
    local    key value
    local    opt arg
    local -A git

    __zplug::utils::shell::getopts "$argv[@]" \
        | while read key value; \
    do
        case "$key" in
            dir)
                git[dir]="$value"
                ;;
            branch)
                git[branch]="$value"
                ;;
        esac
    done

    __zplug::utils::shell::cd \
        "$git[dir]" || return $_ZPLUG_STATUS_REPO_NOT_FOUND

    {
        if [[ -e $git[dir]/.git/shallow ]]; then
            git fetch --unshallow
        else
            git fetch
        fi
        git checkout -q "$git[branch]"
    } 2>&1 | __zplug::io::report::save

    git[local]="$(git rev-parse HEAD)"
    git[upstream]="$(git rev-parse "@{upstream}")"
    git[base]="$(git merge-base HEAD "@{upstream}")"

    if [[ $git[local] == $git[upstream] ]]; then
        # up-to-date
        return $_ZPLUG_STATUS_REPO_UP_TO_DATE

    elif [[ $git[local] == $git[base] ]]; then
        # need to pull
        {
            git merge --ff-only "origin/$git[branch]"
            git submodule update --init --recursive
        } 2>&1 | __zplug::io::report::save
        __zplug::utils::shell::pipestatus
        return $status

    elif [[ $git[upstream] == $git[base] ]]; then
        # need to push
        return $_ZPLUG_STATUS_FAILURE

    else
        # Diverged
        return $_ZPLUG_STATUS_FAILURE
    fi

    return $_ZPLUG_STATUS_SUCCESS
}

__zplug::utils::git::status()
{
    local    repo="${1:?}"
    local    key val line
    local -A revisions

    git ls-remote --heads --tags https://github.com/"$repo".git \
        | awk '{print $2,$1}' \
        | sed -E 's@^refs/(heads|tags)/@@g' \
        | while read line; do
            key=${${(s: :)line}[1]}
            val=${${(s: :)line}[2]}
            revisions[$key]="$val"
        done

    git \
        --git-dir="$ZPLUG_REPOS/$repo/.git" \
        --work-tree="$ZPLUG_REPOS/$repo" \
        log \
        --oneline \
        --pretty="format:%H" \
        --max-count=1 \
        | read val
    revisions[local]="$val"

    reply=( "${(kv)revisions[@]}" )
}

__zplug::utils::git::get_head_branch_name()
{
    local head_branch

    if __zplug::base::base::git_version 1.7.10; then
        head_branch="$(git symbolic-ref -q --short HEAD)"
    else
        head_branch="${$(git symbolic-ref -q HEAD)#refs/heads/}"
    fi

    if [[ -z $head_branch ]]; then
        git rev-parse --short HEAD
        return 1
    fi
    __zplug::io::print::put "$head_branch\n"
}

__zplug::utils::git::get_remote_name()
{
    local branch="${1:?}" remote_name

    remote_name="$(git config branch.${branch}.remote)"
    if [[ -z $remote_name ]]; then
        __zplug::io::print::f \
            --die \
            --zplug \
            "no remote repository\n"
        return 1
    fi

    echo "$remote_name"
}

__zplug::utils::git::get_remote_state()
{
    local    remote_name branch
    local    merge_branch remote_show
    local    state url
    local -a behind_ahead
    local -i behind ahead

    branch="$1"
    remote_name="$(__zplug::utils::git::get_remote_name "$branch")"

    if (( $status == 0 )); then
        merge_branch="${$(git config branch.${branch}.merge)#refs/heads/}"
        remote_show="$(git remote show "$remote_name")"
        state="$(grep "^ *$branch *pushes" <<<"$remote_show" | sed 's/.*(\(.*\)).*/\1/')"

        if [[ -z $state ]]; then
            behind_ahead=( ${(@f)"$(git rev-list \
                --left-right \
                --count \
                "$remote_name/$merge_branch"...$branch)"} )
            behind=$behind_ahead[1]
            ahead=$behind_ahead[2]

            if (( $behind > 0 )); then
                state="local out of date"
            else
                origin_head="${$(git ls-remote origin HEAD)[1]}"
                if ! git rev-parse -q "$origin_head" &>/dev/null; then
                    state="local out of date"
                elif (( $ahead > 0 )); then
                    state="fast-forwardable"
                else
                    state="up to date"
                fi
            fi
        fi

        url="$(grep '^ *Push' <<<"$remote_show" | sed 's/^.*URL: \(.*\)$/\1/')"
    else
        state="$remote_name"
    fi

    echo "$state"
    echo "$url"
}

__zplug::utils::git::get_state()
{
    local    branch
    local -a res
    local    state url

    if [[ ! -e .git ]]; then
        state="not git repo"
    fi

    branch="$(__zplug::utils::git::get_head_branch_name)"
    if (( $status == 0 )); then
        res=( ${(@f)"$(__zplug::utils::git::get_remote_state "$branch")"} )
        state="$res[1]"
        url="$res[2]"
    else
        state="not on any branch"
    fi

    case "$state" in
        "local out of date")
            state="${fg[red]}${state}${reset_color}"
            ;;
        "up to date")
            state="${fg[green]}${state}${reset_color}"
            ;;
    esac

    __zplug::io::print::put "($state) '${url:-?}'\n"
}

__zplug::utils::git::remote_url()
{
    # Check if it has git directory
    [[ -e .git ]] || return 1

    git remote -v \
        | sed -n '1p' \
        | awk '{print $2}'
}
