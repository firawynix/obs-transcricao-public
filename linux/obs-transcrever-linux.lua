obs = obslua
local ativo = true
local idioma = "pt"
local modo = "perguntar"
local cpu_max = 70
local legenda = true

local function ler_app()
    local home = os.getenv("HOME") or ""
    local file = io.open(home .. "/.config/firawynix/obs-transcricao/appimage-path", "r")
    if file == nil then return nil end
    local value = file:read("*l")
    file:close()
    return value
end

local function quote(value)
    return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function transcrever(caminho, manual)
    local aplicativo = ler_app()
    if aplicativo == nil or caminho == nil or caminho == "" then
        obs.script_log(obs.LOG_WARNING, "[Firaw] execute o aplicativo e use Integrar ao OBS primeiro")
        return
    end
    local direto = (not manual) and modo == "direto"
    local cmd = quote(aplicativo) .. " " .. quote(caminho)
    if direto then cmd = cmd .. " --start" end
    cmd = cmd .. " >/dev/null 2>&1 &"
    os.execute(cmd)
end

local function on_event(event)
    if not ativo then return end
    if event == obs.OBS_FRONTEND_EVENT_RECORDING_STOPPED then transcrever(obs.obs_frontend_get_last_recording(), false)
    elseif event == obs.OBS_FRONTEND_EVENT_REPLAY_BUFFER_SAVED then transcrever(obs.obs_frontend_get_last_replay(), false) end
end

local function botao_agora(props, property)
    transcrever(obs.obs_frontend_get_last_recording(), true)
    return false
end

function script_description() return "<b>Firaw OBS Transcricao para Linux</b><br/>Gera TXT e SRT localmente ao encerrar uma gravacao." end
function script_properties()
    local props = obs.obs_properties_create()
    obs.obs_properties_add_bool(props, "ativo", "Transcrever automaticamente")
    local modes = obs.obs_properties_add_list(props, "modo", "Ao parar", obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
    obs.obs_property_list_add_string(modes, "Abrir para revisar", "perguntar")
    obs.obs_property_list_add_string(modes, "Transcrever direto", "direto")
    obs.obs_properties_add_button(props, "agora", "Transcrever ultima gravacao", botao_agora)
    return props
end
function script_defaults(settings) obs.obs_data_set_default_bool(settings, "ativo", true); obs.obs_data_set_default_string(settings, "modo", "perguntar") end
function script_update(settings) ativo = obs.obs_data_get_bool(settings, "ativo"); modo = obs.obs_data_get_string(settings, "modo") end
function script_load(settings) obs.obs_frontend_add_event_callback(on_event) end
