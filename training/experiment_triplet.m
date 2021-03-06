% -------------------------------------------------------------------------------------------------
function [net, stats] = experiment_triplet(imdb_video, varargin)
%EXPERIMENT
%   main function - creates a network and trains it on the dataset indexed by imdb_video.
%
%   Luca Bertinetto, Jack Valmadre, Joao Henriques, 2016

% the enhancers are produced by the training net changed with each iteration
% delete pairwise loss.
% -------------------------------------------------------------------------------------------------
    % Default parameters (set the experiment-specific ones in run_experiment)
    opts.net.type = 'alexnet';
    opts.net.conf = struct(); % Options depend on type of net.
    opts.pretrain = false; % Location of model file set in env_paths.
    opts.init.scale = 1;
    opts.init.weightInitMethod = 'xavierimproved';
    opts.init.initBias = 0.1;
    opts.expDir = 'data'; % where to save the trained net
    opts.numFetchThreads = 12; % used by vl_imreadjpg when reading dataset
    opts.validation = 0.1; % fraction of imbd reserved to validation
    opts.exemplarSize = 127; % exemplar (z) in the paper
    opts.instanceSize = 255 - 2*8; % search region (x) in the paper
    opts.loss.type = 'simple';
    opts.loss.rPos = 16; % pixel with distance from center d > rPos are given a negative label
    opts.loss.rNeg = 0; % if rNeg != 0 pixels rPos < d < rNeg are given a neutral label
    opts.loss.labelWeight = 'balanced';
    opts.numPairs =  5.32e4; % Number of example pairs per epoch, if empty, then equal to number of videos.
    opts.randomSeed = 0;
    opts.shuffleDataset = false; % do not shuffle the data to get reproducible experiments
    opts.frameRange = 100; % range from the exemplar in which randomly pick the instance
    opts.gpus = [];
    opts.prefetch = false; % Both get_batch and cnn_train_dag depend on prefetch.
    opts.train.numEpochs = 50;
    opts.train.learningRate = logspace(-2, -5, opts.train.numEpochs);
    opts.train.weightDecay = 5e-4;
    opts.train.batchSize = 8; % we empirically observed that small batches work better
    opts.train.profile = false;
    % add parameter
%     opts.train.exemplarSize = opts.exemplarSize; % exemplar (z) in the paper
%     opts.train.instanceSize = opts.instanceSize; % search region (x) in the paper
%     opts.loss.weight  = 0.01;
    % Data augmentation settings
    opts.subMean = false;
    opts.colorRange = 255;
    opts.augment.translate = true;
    opts.augment.maxTranslate = 4;
    opts.augment.stretch = true;
    opts.augment.maxStretch = 0.05;
    opts.augment.color = true;
    opts.augment.grayscale = 0; % likelihood of using grayscale pair
    % Override default parameters if specified in run_experiment
    
    % Get environment-specific default paths.
    opts = env_paths_training(opts);
    opts.train.gpus = opts.gpus;
    opts.train.prefetch = opts.prefetch;
    
    opts = vl_argparse(opts, varargin);
% -------------------------------------------------------------------------------------------------
    % Get ImageNet Video metadata
    if isempty(imdb_video)
        fprintf('loading imdb video...\n');
        imdb_video = load(opts.imdbVideoPath);
        imdb_video = imdb_video.imdb_video;
    end

    % Load dataset statistics
    [rgbMean_z, rgbVariance_z, rgbMean_x, rgbVariance_x] = load_stats(opts);
    if opts.shuffleDataset
        s = RandStream.create('mt19937ar', 'Seed', 'shuffle');
        opts.randomSeed = s.Seed;
    end

    opts.train.expDir = opts.expDir;

    rng(opts.randomSeed); % Re-seed before calling make_net.

    % -------------------------------------------------------------------------------------------------
    net = make_net(opts);
    % -------------------------------------------------------------------------------------------------

    [imdb_video, imdb] = choose_val_set(imdb_video, opts);

    [resp_sz, resp_stride] = get_response_size(net, opts);
    % We want an odd number so that we can center the target in the middle
    assert(all(mod(resp_sz, 2) == 1), 'resp. size is not odd');

    [net, derOutputs, label_inputs_fn] = setup_loss(net, resp_sz, resp_stride, opts.loss);

%     enhancer = zeros(a_feat_sz(1),a_feat_sz(2),256,opts.train.batchSize,'single');
% %     imout_t(end)=1;
% %     if numel(opts.train.gpus) >= 1
% %         imout_t = gpuArray(imout_t);
% %     end
%     t_labels = ones(opts.train.batchSize,1);
%     neg_labels = -ones(opts.train.batchSize,1);
    batch_fn = @(db, batch) get_batch(db, batch, ...
                                        imdb_video, ...
                                        opts.rootDataDir, ...
                                        numel(opts.train.gpus) >= 1, ...
                                        struct('exemplarSize', opts.exemplarSize, ...
                                               'instanceSize', opts.instanceSize, ...
                                               'frameRange', opts.frameRange, ...
                                               'subMean', opts.subMean, ...
                                               'colorRange', opts.colorRange, ...
                                               'stats', struct('rgbMean_z', rgbMean_z, ...
                                                               'rgbVariance_z', rgbVariance_z, ...
                                                               'rgbMean_x', rgbMean_x, ...
                                                               'rgbVariance_x', rgbVariance_x), ...
                                               'augment', opts.augment, ...
                                               'prefetch', opts.train.prefetch, ...
                                               'numThreads', opts.numFetchThreads), ...
                                        label_inputs_fn);

    opts.train.derOutputs = derOutputs;
    opts.train.randomSeed = opts.randomSeed;
    % -------------------------------------------------------------------------------------------------
    % Start training
    [net, stats] = cnn_train_dag(net, imdb, batch_fn, opts.train);
    % -------------------------------------------------------------------------------------------------
end


% -----------------------------------------------------------------------------------------------------
function [rgbMean_z, rgbVariance_z, rgbMean_x, rgbVariance_x] = load_stats(opts)
% Dataset image statistics for data augmentation
% -----------------------------------------------------------------------------------------------------
    stats = load(opts.imageStatsPath);
    % Subtracted if opts.subMean is true
    if ~isfield(stats, 'z')
        rgbMean = reshape(stats.rgbMean, [1 1 3]);
        rgbMean_z = rgbMean;
        rgbMean_x = rgbMean;
        [v,d] = eig(stats.rgbCovariance);
        rgbVariance_z = 0.1*sqrt(d)*v';
        rgbVariance_x = 0.1*sqrt(d)*v';
    else
        rgbMean_z = reshape(stats.z.rgbMean, [1 1 3]);
        rgbMean_x = reshape(stats.x.rgbMean, [1 1 3]);
        % Set data augmentation statistics, used if opts.augment.color is true
        [v,d] = eig(stats.z.rgbCovariance);
        rgbVariance_z = 0.1*sqrt(d)*v';
        [v,d] = eig(stats.x.rgbCovariance);
        rgbVariance_x = 0.1*sqrt(d)*v';
    end
end


% -------------------------------------------------------------------------------------------------
function net = make_net(opts)
% -------------------------------------------------------------------------------------------------

    net = make_siam_adapt2(opts);
%     net = make_siameseFC(opts);

    % Save the net graph to disk.
    inputs = {'exemplar', [opts.exemplarSize*[1 1] 3 opts.train.batchSize], ...
              'instance', [opts.instanceSize*[1 1] 3 opts.train.batchSize]};
    net_dot = net.print(inputs, 'Format', 'dot');
    if ~exist(opts.expDir)
        mkdir(opts.expDir);
    end
    f = fopen(fullfile(opts.expDir, 'arch.dot'), 'w');
    fprintf(f, net_dot);
    fclose(f);
end


% -------------------------------------------------------------------------------------------------
function [resp_sz, resp_stride] = get_response_size(net, opts)
% -------------------------------------------------------------------------------------------------

    sizes = net.getVarSizes({'exemplar', [opts.exemplarSize*[1 1] 3 256], ...
                             'instance', [opts.instanceSize*[1 1] 3 256]});
    resp_sz = sizes{net.getVarIndex('score')}(1:2);
    rfs = net.getVarReceptiveFields('exemplar');
    resp_stride = rfs(net.getVarIndex('score')).stride(1);
    assert(all(rfs(net.getVarIndex('score')).stride == resp_stride));
end


% -------------------------------------------------------------------------------------------------
function [net, derOutputs, inputs_fn] = setup_loss(net, resp_sz, resp_stride, loss_opts)
% Add layers to the network, specifies the losses to minimise, and
% constructs a function that returns the inputs required by the loss layers.
% -------------------------------------------------------------------------------------------------
net.addLayer('tri_select', select_pairs(), ...
                 {'score', 'eltwise_label'}, ...
                 {'tri_pairs'}, ...
                 {});
    net.addLayer('objective_softmaxlog', ...
                 dagnn.Loss('loss', 'softmaxlog'), ...
                 {'tri_pairs','tri_pairs_label'}, 'objective_softmaxlog');
   net.vars(end).precious = 1;          
%     %xcorr ac  correlation between exemplar and positive instance           
%     net.addLayer('xcorr_ac', XCorr(), ...
%                  {'a_feat', 'c_feat'}, ...
%                  {'xcorr_ac_out'}, ...
%                  {});
%     add_adjust_layer(net, 'adjust_ac', 'xcorr_ac_out', 'score_ac', ...
%                  {'adjust_f', 'adjust_b'}, 1e-3, 0, 0, 1);
%     %xcorr ad   correlation between exemplar and negative instance       
%     net.addLayer('xcorr_ad', XCorr(), ...
%                  {'a_feat', 'd_feat'}, ...
%                  {'xcorr_ad_out'}, ...
%                  {});
%     add_adjust_layer(net, 'adjust_ad', 'xcorr_ad_out', 'score_ad', ...
%                  {'adjust_f', 'adjust_b'}, 1e-3, 0, 0, 1);
%     
% %     net.addLayer('concat', dagnn.Concat(), ...
% %                  {'score_ac', 'score_ad'}, ...
% %                  {'concat_out'}, ...
% %                  {});
%     % softmaxloss between score_ac and score_ad
%     net.addLayer('objective_softmax', ...
%                  TripletLoss2(), ...
%                  {'score_ac', 'score_ad'}, 'objective_softmax');
% %                  net.layers(end).block.opts = [...
% %         net.layers(end).block.opts, ...
% %         {'instanceWeights', loss_opts.weight}];  
% %     add_adjust_layer(net, 'adjust_loss', 'objective_softmax', 'loss_softmax',  ...
% %                  {'adjust_f_sm', 'adjust_b_sm'}, 1e-3, 0, 1, 0); 
%              
% %     % create label and weights for logistic loss
% %     net.addLayer('objective', ...
% %                  dagnn.Loss('loss', 'logistic'), ...
% %                  {'score', 'eltwise_label'}, 'objective');
% %     % adding weights to loss layer

        
    [pos_eltwise, instanceWeight] = create_labels(...
        resp_sz, loss_opts.labelWeight, ...
        loss_opts.rPos/resp_stride, loss_opts.rNeg/resp_stride);
    neg_eltwise = [];   % no negative pairs at the moment
    
    ind_pos = pos_eltwise>0;
        ind_neg = pos_eltwise<0;
        ind_pos = ind_pos(:);
        ind_neg = ind_neg(:);
        n_pos = sum(ind_pos);
        n_neg = sum(ind_neg);
        ind_select = ones(n_pos,n_neg)>0;
        n_pairs = sum(ind_select(:));
        instanceWeight = ones(1,n_pairs,'single')/n_pairs;
    net.layers(end).block.opts = [...
        net.layers(end).block.opts, ...
        {'instanceWeights', instanceWeight}];
    
%         net.addLayer('sum_loss', ...
%                  dagnn.Sum('numInputs',2), ...
%                  {'objective', 'objective_softmax'}, 'sum_loss');

%         net.addLayer('sum_loss', ...
%                  weightSum('numInputs',2,'ws',[1,loss_opts.weight]), ...
%                  {'objective', 'objective_softmax'}, 'sum_loss');

%      add_norm_weight_sum_layer(net, 'sum_loss', {'objective', 'objective_softmax'}, {'sum_loss'}, ...
%                  {'ws'}, [0.9,0.1], 1);        

%     % loss between a_feat and c_feat
%     net.addLayer('objective_ac', ...
%                  dagnn.Loss('loss', 'logistic'), ...
%                  {'score_ac', 'pos_label'}, 'objective_ac');
%     add_adjust_layer(net, 'adjust', 'score_ac', 'adjust_score_ac',  ...
%                  {'adjust_f_ac', 'adjust_b_ac'}, 1e-3, 0, 1, 0);
%     % loss between a_feat and d_feat
%     net.addLayer('objective_ad', ...
%                  dagnn.Loss('loss', 'logistic'), ...
%                  {'score_ad', 'neg_label'}, 'objective_ad');
%     add_adjust_layer(net, 'adjust', 'score_ad', 'adjust_score_ad',  ...
%                  {'adjust_f_ad', 'adjust_b_ad'}, 1e-3, 0, 1, 0);             
%     net.layers(end).block.opts = [...
%         net.layers(end).block.opts, ...
%         {'instanceWeights', loss_opts.weight}];       
    
%     derOutputs = {'sum_loss', 1};
%     derOutputs = {'objective', 1, 'objective_softmax',1};
    derOutputs = { 'objective_softmaxlog',1};

    inputs_fn = @(labels, obj_sz_z, obj_sz_x) get_label_inputs_simple(...
        labels, obj_sz_z, obj_sz_x, pos_eltwise, neg_eltwise, n_pairs);


    net.addLayer('errdisp', centerThrErr(), {'score', 'label'}, 'errdisp');
    net.addLayer('errmax', MaxScoreErr(), {'score', 'label'}, 'errmax');
end


% -------------------------------------------------------------------------------------------------
function inputs = get_label_inputs_simple(labels, obj_sz_z, obj_sz_x, pos_eltwise, neg_eltwise, n_pairs)
% GET_LABEL_INPUTS_SIMPME returns the network inputs that specify the labels.
%
% labels -- Label of +1 or -1 per image pair, size [1, n].
% obj_sz_z -- Size of exemplar box, dims [2, n].
% obj_sz_x -- Size of instance box, dims [2, n].
% -------------------------------------------------------------------------------------------------

%     pos = (labels > 0);
%     neg = (labels < 0);
% 
%     resp_sz = size(pos_eltwise);
%     eltwise_labels = zeros([resp_sz, 1, numel(labels)], 'single');
%     eltwise_labels(:,:,:,pos) = repmat(pos_eltwise, [1 1 1 sum(pos)]);
%     eltwise_labels(:,:,:,neg) = repmat(neg_eltwise, [1 1 1 sum(neg)]);
        label0 = ones(1,n_pairs,1,numel(labels),'single');
    inputs = {'label', labels, ...
              'eltwise_label', pos_eltwise,...
              'tri_pairs_label',label0};
%           inputs = {'label', labels};
end


% -------------------------------------------------------------------------------------------------
function [imdb_video, imdb] = choose_val_set(imdb_video, opts)
% Designates some examples for validation.
% It modifies imdb_video and constructs a dummy imdb.
% -------------------------------------------------------------------------------------------------
    TRAIN_SET = 1;
    VAL_SET = 2;

    % set opts.validation to validation and the rest to training.
    size_dataset = numel(imdb_video.id);
    size_validation = round(opts.validation * size_dataset);
    size_training = size_dataset - size_validation;
    imdb_video.set = uint8(zeros(1, size_dataset));
    imdb_video.set(1:size_training) = TRAIN_SET;
    imdb_video.set(size_training+1:end) = VAL_SET;

    %% create imdb of indexes to imdb_video
    % train and val from disjoint video sets
    imdb = struct();
    imdb.images = struct(); % we keep the images struct for consistency with cnn_train_dag (MatConvNet)
    imdb.id = 1:opts.numPairs;
    n_pairs_train = round(opts.numPairs * (1-opts.validation));
    imdb.images.set = uint8(zeros(1, opts.numPairs)); % 1 -> train
    imdb.images.set(1:n_pairs_train) = TRAIN_SET;
    imdb.images.set(n_pairs_train+1:end) = VAL_SET;
end


% -------------------------------------------------------------------------------------------------
function inputs = get_batch(db, batch, imdb_video, data_dir, use_gpu, sample_opts, label_inputs_fn)
% Returns the inputs to the network.
% -------------------------------------------------------------------------------------------------

    [imout_z, imout_x, labels, sizes_z, sizes_x] = vid_get_random_batch(...
        db, imdb_video, batch, data_dir, sample_opts);
    if use_gpu
        imout_z = gpuArray(imout_z);
        imout_x = gpuArray(imout_x);
    end
    % Constructs full label inputs from output of vid_get_random_batch.
    label_inputs = label_inputs_fn(labels, sizes_z, sizes_x);
    inputs = [{'exemplar', imout_z, 'instance', imout_x}, label_inputs];
end
