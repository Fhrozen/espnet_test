#!/usr/bin/env bash

# Copyright 2021 Kyoto University (Hirofumi Inaguma)
#  Apache 2.0  (http://www.apache.org/licenses/LICENSE-2.0)

. ./path.sh || exit 1;
. ./cmd.sh || exit 1;

# general configuration
backend=pytorch
stage=-1        # start from -1 if you need to start from data download
stop_stage=100
ngpu=2          # number of gpus during training ("0" uses cpu, otherwise use gpu)
dec_ngpu=0      # number of gpus during decoding ("0" uses cpu, otherwise use gpu)
nj=8            # number of parallel jobs for decoding
debugmode=1
dumpdir=dump    # directory to dump full features
N=0             # number of minibatches to be used (mainly for debugging). "0" uses all minibatches.
verbose=0       # verbose option
resume=         # Resume the training from snapshot
seed=1          # seed to generate random number
# feature configuration
do_delta=false

preprocess_config=conf/specaug.yaml
train_config=conf/train.yaml
lm_config=conf/lm.yaml
decode_config=conf/decode.yaml

# rnnlm related
lm_resume=        # specify a snapshot file to resume LM training
lmtag=            # tag for managing LMs

# decoding parameter
recog_model=model.acc.best # set a model to be used for decoding: 'model.acc.best' or 'model.loss.best'

# model average realted (only for transformer)
n_average=5                  # the number of ASR models to be averaged
use_valbest_average=true     # if true, the validation `n_average`-best ASR models will be averaged.
                             # if false, the last `n_average` ASR models will be averaged.
metric=acc                   # loss/acc/cer/cer_ctc

# preprocessing related
src_case=lc.rm
# tc: truercase
# lc: lowercase
# lc.rm: lowercase with punctuation removal

cv_datadir=/n/rd8/covost2 # original data directory to be stored
covost2_datadir=download/translation # original data directory to be stored

# language related
src_lang=es
tgt_lang=en
# English (en)
# French (fr)
# German (de)
# Spanish (es)
# Catalan (ca)
# Italian (it)
# Russian (ru)
# Chinese (zh-CN)
# Portuguese (pt)
# Persian (fa)
# Estonian (et)
# Mongolian (mn)
# Dutch (nl)
# Turkish (tr)
# Arabic (ar)
# Swedish (sv-SE)
# Latvian (lv)
# Slovenian (sl)
# Tamil (ta)
# Japanese (ja)
# Indonesian (id)
# Welsh (cy)

# bpemode (unigram or bpe)
nbpe=1000
bpemode=bpe

# exp tag
tag="" # tag for managing experiments.

. utils/parse_options.sh || exit 1;

# Set bash to 'debug' mode, it will exit on :
# -e 'error', -u 'undefined variable', -o ... 'error in pipeline', -x 'print commands',
set -e
set -u
set -o pipefail

train_set=train_sp.${src_lang}-${tgt_lang}.${src_lang}
train_dev=dev.${src_lang}-${tgt_lang}.${src_lang}
recog_set="dev_org.${src_lang}-${tgt_lang}.${src_lang} test.${src_lang}-${tgt_lang}.${src_lang}"

# verify language directions
is_exist=false
is_low_resource=false
if [[ ${src_lang} == en ]]; then
    tgt_langs=de_ca_zh-CN_fa_et_mn_tr_ar_sv-SE_lv_sl_ta_ja_id_cy
    for lang in $(echo ${tgt_langs} | tr '_' ' '); do
        if [[ ${lang} == "${tgt_lang}" ]]; then
            is_exist=true
            break
        fi
    done
else
    lr_src_langs=it_ru_zh-CN_pt_fa_et_mn_nl_tr_ar_sv-SE_lv_sl_ta_ja_id_cy
    for lang in $(echo ${lr_src_langs} | tr '_' ' '); do
        if [[ ${lang} == "${src_lang}" ]]; then
            is_low_resource=true
            break
        fi
    done
    src_langs=fr_de_es_ca_it_ru_zh-CN_pt_fa_et_mn_nl_tr_ar_sv-SE_lv_sl_ta_ja_id_cy
    for lang in $(echo ${src_langs} | tr '_' ' '); do
        if [[ ${lang} == "${src_lang}" ]]; then
            is_exist=true
            break
        fi
    done
fi
if [[ ${is_exist} == false ]]; then
    echo "No language direction: ${src_lang} to ${tgt_lang}" && exit 1;
fi

if [ ${src_lang} == ja ] || [ ${src_lang} == zh-CN ]; then
    nbpe=4000
fi

if [ ${stage} -le -1 ] && [ ${stop_stage} -ge -1 ]; then
    echo "stage -1: Data Download"
    mkdir -p ${cv_datadir} ${covost2_datadir}

    # base url for downloads.
    data_url=https://voice-prod-bundler-ee1969a6ce8178826482b88e843c335139bd3fb4.s3.amazonaws.com/cv-corpus-4-2019-12-10/${src_lang}.tar.gz

    # Download CommonVoice
    mkdir -p ${cv_datadir}/${src_lang}
    local/download_and_untar_commonvoice.sh ${cv_datadir}/${src_lang} ${data_url} ${src_lang}.tar.gz

    # Download translation
    if [[ ${src_lang} != en ]]; then
        wget --no-check-certificate https://dl.fbaipublicfiles.com/covost/covost_v2.${src_lang}_${tgt_lang}.tsv.tar.gz \
            -P ${covost2_datadir}
        tar -xzf ${covost2_datadir}/covost_v2.${src_lang}_${tgt_lang}.tsv.tar.gz -C ${covost2_datadir}
    fi
    wget --no-check-certificate https://dl.fbaipublicfiles.com/covost/covost2.zip \
          -P ${covost2_datadir}
    unzip ${covost2_datadir}/covost2.zip -d ${covost2_datadir}
    # NOTE: some non-English target languages lack translation from English
fi

if [ ${stage} -le 0 ] && [ ${stop_stage} -ge 0 ]; then
    ### Task dependent. You have to make data the following preparation part by yourself.
    ### But you can utilize Kaldi recipes in most cases

    # use underscore-separated names in data directories.
    local/data_prep_commonvoice.pl "${cv_datadir}/${src_lang}" validated data/validated.${src_lang}

    # text preprocessing (tokenization, case, punctuation marks etc.)
    local/data_prep_covost2.sh ${covost2_datadir} ${src_lang} ${tgt_lang} || exit 1;
    # NOTE: train/dev/test splits are different from original CommonVoice
fi

feat_tr_dir=${dumpdir}/${train_set}/delta${do_delta}; mkdir -p ${feat_tr_dir}
feat_dt_dir=${dumpdir}/${train_dev}/delta${do_delta}; mkdir -p ${feat_dt_dir}
if [ ${stage} -le 1 ] && [ ${stop_stage} -ge 1 ]; then
    ### Task dependent. You have to design training and dev sets by yourself.
    ### But you can utilize Kaldi recipes in most cases
    echo "stage 1: Feature Generation"
    fbankdir=fbank
    # Generate the fbank features; by default 80-dimensional fbanks with pitch on each frame
    for x in dev.${src_lang}-${tgt_lang} test.${src_lang}-${tgt_lang}; do
        steps/make_fbank_pitch.sh --cmd "$train_cmd" --nj 32 --write_utt2num_frames true \
            data/${x} exp/make_fbank/${x} ${fbankdir}
        utils/fix_data_dir.sh data/${x}
    done

    # speed perturbation
    if [ ${src_lang} = en ]; then
        speed_perturb.sh --cmd "$train_cmd" --speeds "1.0"                 --cases "lc.rm lc tc" --langs "${src_lang} ${tgt_lang}" data/train.${src_lang}-${tgt_lang} data/train_sp.${src_lang}-${tgt_lang} ${fbankdir}
    elif [ ${is_low_resource} = true ]; then
        speed_perturb.sh --cmd "$train_cmd" --speeds "0.8 0.9 1.0 1.1 1.2" --cases "lc.rm lc tc" --langs "${src_lang} ${tgt_lang}" data/train.${src_lang}-${tgt_lang} data/train_sp.${src_lang}-${tgt_lang} ${fbankdir}
    else
        speed_perturb.sh --cmd "$train_cmd" --speeds "0.9 1.0 1.1"         --cases "lc.rm lc tc" --langs "${src_lang} ${tgt_lang}" data/train.${src_lang}-${tgt_lang} data/train_sp.${src_lang}-${tgt_lang} ${fbankdir}
    fi

    # Divide into source and target languages
    for x in train_sp.${src_lang}-${tgt_lang} dev.${src_lang}-${tgt_lang} test.${src_lang}-${tgt_lang}; do
        divide_lang.sh ${x} "${src_lang} ${tgt_lang}"
    done
    for lang in ${src_lang} ${tgt_lang}; do
        cp -rf data/dev.${src_lang}-${tgt_lang}.${lang} data/dev_org.${src_lang}-${tgt_lang}.${lang}
    done

    # remove long and short utterances
    for x in train_sp.${src_lang}-${tgt_lang} dev.${src_lang}-${tgt_lang}; do
        clean_corpus.sh --maxframes 3000 --maxchars 400 --utt_extra_files "text.tc text.lc text.lc.rm" data/${x} "${src_lang} ${tgt_lang}"
    done

    # compute global CMVN
    compute-cmvn-stats scp:data/${train_set}/feats.scp data/${train_set}/cmvn.ark

    # dump features for training
    dump.sh --cmd "$train_cmd" --nj 80 --do_delta ${do_delta} \
        data/${train_set}/feats.scp data/${train_set}/cmvn.ark exp/dump_feats/${train_set} ${feat_tr_dir}
    for x in ${train_dev} ${recog_set}; do
        feat_dir=${dumpdir}/${x}/delta${do_delta}; mkdir -p ${feat_dir}
        dump.sh --cmd "$train_cmd" --nj 32 --do_delta ${do_delta} \
            data/${x}/feats.scp data/${train_set}/cmvn.ark exp/dump_feats/recog/${x} ${feat_dir}
    done
fi

dict=data/lang_1spm/${train_set}_${bpemode}${nbpe}_units_${src_case}.txt
nlsyms=data/lang_1spm/${train_set}_non_lang_syms_${src_case}.txt
bpemodel=data/lang_1spm/${train_set}_${bpemode}${nbpe}_${src_case}
echo "dictionary: ${dict}"
if [ ${stage} -le 2 ] && [ ${stop_stage} -ge 2 ]; then
    ### Task dependent. You have to check non-linguistic symbols used in the corpus.
    echo "stage 2: Dictionary and Json Data Preparation"
    mkdir -p data/lang_1spm/

    echo "make a non-linguistic symbol list for all languages"
    grep sp1.0 data/${train_set}/text.${src_case} | cut -f 2- -d' ' | grep -o -P '&[^;]*;'| sort | uniq > ${nlsyms}
    cat ${nlsyms}

    echo "make a dictionary"
    echo "<unk> 1" > ${dict} # <unk> must be 1, 0 will be used for "blank" in CTC
    offset=$(wc -l < ${dict})
    grep sp1.0 data/${train_set}/text.${src_case} | cut -f 2- -d' ' | grep -v -e '^\s*$' > data/lang_1spm/input_${src_lang}_${tgt_lang}_${src_case}.txt
    spm_train --user_defined_symbols="$(tr "\n" "," < ${nlsyms})" --input=data/lang_1spm/input_${src_lang}_${tgt_lang}_${src_case}.txt \
        --vocab_size=${nbpe} --model_type=${bpemode} --model_prefix=${bpemodel} --input_sentence_size=100000000 --character_coverage=0.9995
    spm_encode --model=${bpemodel}.model --output_format=piece < data/lang_1spm/input_${src_lang}_${tgt_lang}_${src_case}.txt \
        | tr ' ' '\n' | sort | uniq | awk -v offset=${offset} '{print $0 " " NR+offset}' >> ${dict}
    wc -l ${dict}
    # NOTE: change coverage for Japanese

    echo "make json files"
    for x in ${train_set} ${train_dev} ${recog_set}; do
        feat_dir=${dumpdir}/${x}/delta${do_delta}
        data2json.sh --nj 16 --feat ${feat_dir}/feats.scp --text data/${x}/text.${src_case} --bpecode ${bpemodel}.model \
            data/${x} ${dict} > ${feat_dir}/data_${bpemode}${nbpe}.${src_case}.json
    done
fi

# You can skip this and remove --rnnlm option in the recognition (stage 3)
if [ -z ${lmtag} ]; then
    lmtag=$(basename ${lm_config%.*})_${src_case}
fi
lmexpname=${train_set}_${src_case}_rnnlm_${backend}_${lmtag}_${bpemode}${nbpe}
lmexpdir=exp/${lmexpname}
mkdir -p ${lmexpdir}

if [ ${stage} -le 3 ] && [ ${stop_stage} -ge 3 ]; then
    echo "stage 3: LM Preparation"
    lmdatadir=data/local/lm_${train_set}_${bpemode}${nbpe}
    mkdir -p ${lmdatadir}
    grep sp1.0 data/${train_set}/text.${src_case} | cut -f 2- -d " " | spm_encode --model=${bpemodel}.model --output_format=piece \
        > ${lmdatadir}/train_${src_case}.txt
    cut -f 2- -d " " data/${train_dev}/text.${src_case} | spm_encode --model=${bpemodel}.model --output_format=piece \
        > ${lmdatadir}/valid_${src_case}.txt
    ${cuda_cmd} --gpu ${ngpu} ${lmexpdir}/train.log \
        lm_train.py \
        --config ${lm_config} \
        --ngpu ${ngpu} \
        --backend ${backend} \
        --verbose 1 \
        --outdir ${lmexpdir} \
        --tensorboard-dir tensorboard/${lmexpname} \
        --train-label ${lmdatadir}/train_${src_case}.txt \
        --valid-label ${lmdatadir}/valid_${src_case}.txt \
        --resume ${lm_resume} \
        --dict ${dict}
fi

if [ -z ${tag} ]; then
    expname=${train_set}_${src_case}_${backend}_$(basename ${train_config%.*})_${bpemode}${nbpe}
    if ${do_delta}; then
        expname=${expname}_delta
    fi
    if [ -n "${preprocess_config}" ]; then
        expname=${expname}_$(basename ${preprocess_config%.*})
    fi
else
    expname=${train_set}_${src_case}_${backend}_${tag}
fi
expdir=exp/${expname}
mkdir -p ${expdir}

if [ ${stage} -le 4 ] && [ ${stop_stage} -ge 4 ]; then
    echo "stage 4: Network Training"

    ${cuda_cmd} --gpu ${ngpu} ${expdir}/train.log \
        asr_train.py \
        --config ${train_config} \
        --preprocess-conf ${preprocess_config} \
        --ngpu ${ngpu} \
        --backend ${backend} \
        --outdir ${expdir}/results \
        --tensorboard-dir tensorboard/${expname} \
        --debugmode ${debugmode} \
        --dict ${dict} \
        --debugdir ${expdir} \
        --minibatches ${N} \
        --seed ${seed} \
        --verbose ${verbose} \
        --resume ${resume} \
        --train-json ${feat_tr_dir}/data_${bpemode}${nbpe}.${src_case}.json \
        --valid-json ${feat_dt_dir}/data_${bpemode}${nbpe}.${src_case}.json \
        --n-iter-processes 2
fi

if [ ${stage} -le 5 ] && [ ${stop_stage} -ge 5 ]; then
    echo "stage 5: Decoding"
    if [[ $(get_yaml.py ${train_config} model-module) = *transformer* ]] || \
       [[ $(get_yaml.py ${train_config} model-module) = *conformer* ]] || \
       [[ $(get_yaml.py ${train_config} etype) = custom ]] || \
       [[ $(get_yaml.py ${train_config} dtype) = custom ]]; then
        # Average ASR models
        if ${use_valbest_average}; then
            recog_model=model.val${n_average}.avg.best
            opt="--log ${expdir}/results/log --metric ${metric}"
        else
            recog_model=model.last${n_average}.avg.best
            opt="--log"
        fi
        average_checkpoints.py \
            ${opt} \
            --backend ${backend} \
            --snapshots ${expdir}/results/snapshot.ep.* \
            --out ${expdir}/results/${recog_model} \
            --num ${n_average}
    fi

    if [ ${dec_ngpu} = 1 ]; then
        nj=1
    fi

    pids=() # initialize pids
    for x in ${recog_set}; do
    (
        decode_dir=decode_${x}_$(basename ${decode_config%.*})
        feat_dir=${dumpdir}/${x}/delta${do_delta}

        # reset log for RTF calculation
        if [ -f ${expdir}/${decode_dir}/log/decode.1.log ]; then
            rm ${expdir}/${decode_dir}/log/decode.*.log
        fi

        # split data
        splitjson.py --parts ${nj} ${feat_dir}/data_${bpemode}${nbpe}.${src_case}.json

        ${decode_cmd} JOB=1:${nj} ${expdir}/${decode_dir}/log/decode.JOB.log \
            asr_recog.py \
            --config ${decode_config} \
            --ngpu ${dec_ngpu} \
            --backend ${backend} \
            --batchsize 0 \
            --recog-json ${feat_dir}/split${nj}utt/data_${bpemode}${nbpe}.JOB.json \
            --result-label ${expdir}/${decode_dir}/data.JOB.json \
            --model ${expdir}/results/${recog_model} \
            --rnnlm ${lmexpdir}/rnnlm.model.best

        score_sclite_case.sh --case ${src_case} --bpe ${nbpe} --bpemodel ${bpemodel}.model --wer true \
            ${expdir}/${decode_dir} ${dict}
        # TODO: support ja and zh-CN

        calculate_rtf.py --log-dir ${expdir}/${decode_dir}/log
    ) &
    pids+=($!) # store background pids
    done
    i=0; for pid in "${pids[@]}"; do wait ${pid} || ((++i)); done
    [ ${i} -gt 0 ] && echo "$0: ${i} background jobs are failed." && false
    echo "Finished"
fi
